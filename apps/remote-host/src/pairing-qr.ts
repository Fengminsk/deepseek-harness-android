/**
 * 远程 DSH 的配对二维码：把配对链接编码成 QR 矩阵，并渲染成终端字符画。
 *
 * 配对链接固定是 `wss://<host>:<port>#instance=<64 hex>&token=<43 base64url>`：
 * 令牌 43 个字符、指纹 64 个字符，手机配对页（`apps/android/lib/remote_pairing_page.dart`）
 * 又只有「粘贴链接」一个入口，手输不现实。宿主 stderr 直接连终端时，`./index.ts` 用
 * 这里的结果把链接画成二维码，用户扫码后复制文本再粘贴。
 *
 * 纯 Node 实现，不引依赖，只覆盖本场景：字节模式、纠错等级 M、版本 1–10。版本 10 的
 * M 级数据容量 216 字节，最长的一条配对链接（约 200 字节）也放得下。
 *
 * 契约：{@link encodeQrMatrix} 要么返回完整矩阵，要么抛错，不返回半张图；
 * {@link renderTerminalQr} 只做渲染，不做 I/O。矩阵正确性由
 * `apps/remote-host/scripts/qr-selfcheck.ts` 证明：它逐模块对照手机 App 已在用的
 * `qr 3.0.2`（qr_flutter 的依赖），并独立回读数据位、验 Reed-Solomon 综合。
 * @module remote-host/pairing-qr
 */

/** 纠错等级 M 在 QR 格式信息里的编码（规范：L=1、M=0、Q=3、H=2）。 */
const QR_ERROR_CORRECTION_M = 0

/** 本实现支持的最高版本；矩阵边长等于 `17 + 4 × 版本`。 */
const QR_MAX_VERSION = 10

/** 矩阵单元还没写过：构造过程中只用于判重，交付的矩阵里不允许存在。 */
const QR_CELL_UNSET = 0

/** 矩阵单元是浅色模块。 */
const QR_CELL_LIGHT = 1

/** 矩阵单元是深色模块。 */
const QR_CELL_DARK = 2

/** 版本 1–10、纠错等级 M 的 RS 分块表：`[块数, 每块总码字, 每块数据码字, …]`。 */
const QR_RS_BLOCKS_M: readonly (readonly number[])[] = [
  [1, 26, 16],
  [1, 44, 28],
  [1, 70, 44],
  [2, 50, 32],
  [2, 67, 43],
  [4, 43, 27],
  [4, 49, 31],
  [2, 60, 38, 2, 61, 39],
  [3, 58, 36, 2, 59, 37],
  [4, 69, 43, 1, 70, 44],
]

/** 版本 1–10 的校正图形中心坐标（第一项 6 与定位图形同行同列，规范固定）。 */
const QR_ALIGNMENT_POSITIONS: readonly (readonly number[])[] = [
  [],
  [6, 18],
  [6, 22],
  [6, 26],
  [6, 30],
  [6, 34],
  [6, 22, 38],
  [6, 24, 42],
  [6, 26, 46],
  [6, 28, 50],
]

/** 格式信息（15 位 BCH）的生成多项式 G15。 */
const QR_FORMAT_GENERATOR = 0b10100110111

/** 格式信息落盘前必须异或的固定掩码（规范常量）。 */
const QR_FORMAT_MASK = 0b101010000010010

/** 版本信息（18 位 BCH）的生成多项式 G18。 */
const QR_VERSION_GENERATOR = 0b1111100100101

/** GF(256) 的指数表与对数表。 */
interface GaloisTables {
  /** 指数表：`exp[i] = α^i`；长度 512，便于连乘时不用先取模。 */
  readonly exp: Uint8Array
  /** 对数表：`log[α^i] = i`；`log[0]` 没有定义，留 0 且不会被读到。 */
  readonly log: Uint8Array
}

/**
 * 按本原多项式 x^8 + x^4 + x^3 + x^2 + 1 展开 GF(256) 的表。
 * @returns 指数表与对数表。
 */
function createGaloisTables(): GaloisTables {
  const exp = new Uint8Array(512)
  const log = new Uint8Array(256)
  let value = 1
  for (let index = 0; index < 255; index += 1) {
    exp[index] = value
    log[value] = index
    // 乘 2 等价于左移后对本原多项式取余；进位结果就是 0x11d 的低 8 位 0x1d。
    value <<= 1
    if ((value & 0x100) !== 0) value ^= 0x11d
  }
  for (let index = 255; index < 512; index += 1) exp[index] = exp[index - 255] ?? 0
  return { exp, log }
}

/** GF(256) 的表；模块加载时建一次。 */
const QR_GALOIS = createGaloisTables()

/**
 * GF(256) 上做乘法。
 * @param left - 第一个乘数。
 * @param right - 第二个乘数。
 * @returns 乘积。
 */
function galoisMultiply(left: number, right: number): number {
  if (left === 0 || right === 0) return 0
  return QR_GALOIS.exp[(QR_GALOIS.log[left] ?? 0) + (QR_GALOIS.log[right] ?? 0)] ?? 0
}

/**
 * 取一个必然存在的表项。
 *
 * 表的长度由版本号范围保证；取不到说明「表与版本号失配」，属于实现错误，直接抛出
 * 而不是给出 0 让二维码悄悄错下去。
 * @param value - 表项读取结果。
 * @param name - 表名，用于报错。
 * @returns 该表项。
 * @throws 表项缺失时抛出。
 */
function requiredEntry<T>(value: T | undefined, name: string): T {
  if (value === undefined) throw new Error(`二维码${name}表缺少对应项。`)
  return value
}

/**
 * 读取只读数字表的一项。
 * @param table - 数字表。
 * @param index - 下标。
 * @returns 该项。
 * @throws 下标越界时抛出。
 */
function tableNumber(table: readonly number[], index: number): number {
  return requiredEntry(table[index], '')
}

/** 一个 RS 块的码字数量：总码字 = 数据码字 + 纠错码字。 */
interface QrBlock {
  /** 每块总码字。 */
  readonly totalCount: number
  /** 每块数据码字。 */
  readonly dataCount: number
}

/** 方形模块阵列：行优先的一维数组，值取 {@link QR_CELL_UNSET} / {@link QR_CELL_LIGHT} / {@link QR_CELL_DARK}。 */
type QrGrid = Uint8Array

/**
 * 读取矩阵单元。
 * @param grid - 模块阵列。
 * @param size - 边长。
 * @param row - 行号。
 * @param column - 列号。
 * @returns 单元状态。
 */
function cellAt(grid: QrGrid, size: number, row: number, column: number): number {
  return grid[row * size + column] ?? QR_CELL_UNSET
}

/**
 * 写入矩阵单元。
 * @param grid - 模块阵列。
 * @param size - 边长。
 * @param row - 行号。
 * @param column - 列号。
 * @param value - 单元状态。
 */
function setCell(grid: QrGrid, size: number, row: number, column: number, value: number): void {
  grid[row * size + column] = value
}

/** 一张已经排好、但还停留在模块级的二维码。 */
export interface QrMatrix {
  /** QR 版本号（1–10）。 */
  readonly version: number
  /** 矩阵边长（模块数），等于 `17 + version × 4`。 */
  readonly size: number
  /** 掩码编号 0–7，已经写进格式信息。 */
  readonly mask: number
  /** 按行存放的模块矩阵，`true` 为深色；不含二维码四周的安静区。 */
  readonly modules: readonly (readonly boolean[])[]
}

/**
 * 把版本号展开成逐块的码字数量。
 * @param version - QR 版本号（1–10）。
 * @returns 逐块的 {@link QrBlock}；同一版本内各块数据量可能相差 1。
 */
function qrBlocks(version: number): readonly QrBlock[] {
  const table = requiredEntry(QR_RS_BLOCKS_M[version - 1], 'RS 分块')
  const blocks: QrBlock[] = []
  for (let index = 0; index < table.length; index += 3) {
    const count = tableNumber(table, index)
    const totalCount = tableNumber(table, index + 1)
    const dataCount = tableNumber(table, index + 2)
    for (let repeat = 0; repeat < count; repeat += 1) blocks.push({ totalCount, dataCount })
  }
  return blocks
}

/**
 * 字节模式的数据位长度：模式指示符 4 位 + 字符计数 + 每个字节 8 位。
 * @param byteLength - 待编码的字节数。
 * @param version - QR 版本号，决定字符计数位宽。
 * @returns 数据位的总长度。
 */
function qrDataBitLength(byteLength: number, version: number): number {
  return 4 + (version < 10 ? 8 : 16) + byteLength * 8
}

/**
 * 选能装下全部字节的最小版本。
 * @param byteLength - 待编码的字节数。
 * @returns 版本号与分块表。
 * @throws 版本 10 也装不下时抛出（配对链接最坏情况远小于该容量）。
 */
function qrSelectVersion(byteLength: number): { readonly version: number; readonly blocks: readonly QrBlock[] } {
  for (let version = 1; version <= QR_MAX_VERSION; version += 1) {
    const blocks = qrBlocks(version)
    const capacity = blocks.reduce((total, block) => total + block.dataCount, 0) * 8
    if (qrDataBitLength(byteLength, version) <= capacity) return { version, blocks }
  }
  throw new Error(`配对二维码内容太长：${byteLength} 字节超过版本 ${QR_MAX_VERSION} 的容量。`)
}

/**
 * 把一段比特写进数组（高位在前）。
 * @param bits - 目标比特数组，按写顺序追加。
 * @param value - 待写入的整数。
 * @param length - 写入的位数。
 */
function appendBits(bits: number[], value: number, length: number): void {
  for (let shift = length - 1; shift >= 0; shift -= 1) bits.push((value >>> shift) & 1)
}

/**
 * 比特数组补零到整字节并打包。
 * @param bits - 长度为 8 的倍数的比特数组。
 * @returns 逐字节的码字。
 */
function bitsToBytes(bits: readonly number[]): number[] {
  const bytes: number[] = []
  for (let index = 0; index < bits.length; index += 8) {
    let byte = 0
    for (let offset = 0; offset < 8; offset += 1) byte = (byte << 1) | (bits[index + offset] ?? 0)
    bytes.push(byte)
  }
  return bytes
}

/**
 * 计算一个数据块的纠错码字（多项式除法取余）。
 * @param data - 数据码字。
 * @param errorCount - 需要的纠错码字数。
 * @returns 长度为 `errorCount` 的纠错码字。
 */
function qrErrorCorrection(data: readonly number[], errorCount: number): number[] {
  // 生成多项式 g(x) = ∏(x - α^i)，系数按最高次在前存放，首项恒为 1。
  let generator: number[] = [1]
  for (let index = 0; index < errorCount; index += 1) {
    const factor = QR_GALOIS.exp[index] ?? 0
    const next = new Array<number>(generator.length + 1).fill(0)
    next[0] = generator[0] ?? 1
    for (let coefficient = 1; coefficient < generator.length; coefficient += 1) {
      next[coefficient] = (generator[coefficient] ?? 0)
        ^ galoisMultiply(generator[coefficient - 1] ?? 0, factor)
    }
    next[generator.length] = galoisMultiply(generator[generator.length - 1] ?? 0, factor)
    generator = next
  }
  const remainder = new Array<number>(errorCount).fill(0)
  for (const byte of data) {
    const factor = byte ^ (remainder[0] ?? 0)
    remainder.shift()
    remainder.push(0)
    for (let index = 0; index < errorCount; index += 1) {
      remainder[index] = (remainder[index] ?? 0) ^ galoisMultiply(generator[index + 1] ?? 0, factor)
    }
  }
  return remainder
}

/**
 * 把数据切成 RS 块、算纠错码字并按规范交错成最终码字序列。
 * @param dataBytes - 已补齐的整块数据码字。
 * @param blocks - 分块表。
 * @returns 最终写进矩阵的码字序列。
 */
function qrInterleave(dataBytes: readonly number[], blocks: readonly QrBlock[]): number[] {
  const dataBlocks: number[][] = []
  const errorBlocks: number[][] = []
  let offset = 0
  for (const block of blocks) {
    const data = dataBytes.slice(offset, offset + block.dataCount)
    offset += block.dataCount
    dataBlocks.push(data)
    errorBlocks.push(qrErrorCorrection(data, block.totalCount - block.dataCount))
  }
  const codewords: number[] = []
  const maxData = Math.max(...dataBlocks.map(block => block.length))
  for (let index = 0; index < maxData; index += 1) {
    for (const block of dataBlocks) {
      const byte = block[index]
      if (byte !== undefined) codewords.push(byte)
    }
  }
  const maxError = Math.max(...errorBlocks.map(block => block.length))
  for (let index = 0; index < maxError; index += 1) {
    for (const block of errorBlocks) {
      const byte = block[index]
      if (byte !== undefined) codewords.push(byte)
    }
  }
  return codewords
}

/**
 * 把一段文本编码成最终码字序列。
 * @param text - 待编码文本，按 UTF-8 取字节（配对链接是纯 ASCII）。
 * @param version - 已选定的版本号。
 * @param blocks - 该版本的分块表。
 * @returns 最终码字序列（数据块交错在前、纠错块交错在后）。
 */
function qrCodewords(text: string, version: number, blocks: readonly QrBlock[]): number[] {
  const bytes = [...Buffer.from(text, 'utf8')]
  const capacity = blocks.reduce((total, block) => total + block.dataCount, 0) * 8
  const bits: number[] = []
  appendBits(bits, 0b0100, 4)
  appendBits(bits, bytes.length, version < 10 ? 8 : 16)
  for (const byte of bytes) appendBits(bits, byte, 8)
  if (bits.length > capacity) throw new Error('配对二维码内容超出所选版本的容量。')
  // 终止符最多 4 位；剩余空间不够 4 位时补 0 到底即可。
  if (bits.length + 4 <= capacity) appendBits(bits, 0, 4)
  while (bits.length % 8 !== 0) bits.push(0)
  const padding = [0xec, 0x11]
  const dataBytes = bitsToBytes(bits)
  for (let index = 0; dataBytes.length < capacity / 8; index += 1) {
    dataBytes.push(padding[index % 2] ?? 0xec)
  }
  return qrInterleave(dataBytes, blocks)
}

/**
 * 计算格式信息：2 位纠错等级 + 3 位掩码，接 10 位 BCH 校验，再异或固定掩码。
 * @param data - `纠错等级 << 3 | 掩码`。
 * @returns 15 位格式信息。
 */
function qrFormatBits(data: number): number {
  let remainder = data << 10
  while (bitLength(remainder) - bitLength(QR_FORMAT_GENERATOR) >= 0) {
    remainder ^= QR_FORMAT_GENERATOR << (bitLength(remainder) - bitLength(QR_FORMAT_GENERATOR))
  }
  return ((data << 10) | remainder) ^ QR_FORMAT_MASK
}

/**
 * 计算版本信息：6 位版本号 + 12 位 BCH 校验（版本 7 起才有）。
 * @param version - QR 版本号。
 * @returns 18 位版本信息。
 */
function qrVersionBits(version: number): number {
  let remainder = version << 12
  while (bitLength(remainder) - bitLength(QR_VERSION_GENERATOR) >= 0) {
    remainder ^= QR_VERSION_GENERATOR << (bitLength(remainder) - bitLength(QR_VERSION_GENERATOR))
  }
  return (version << 12) | remainder
}

/**
 * 整数占用的有效位数。
 * @param value - 非负整数。
 * @returns 有效位数，0 为 0。
 */
function bitLength(value: number): number {
  let count = 0
  let current = value
  while (current !== 0) {
    count += 1
    current >>>= 1
  }
  return count
}

/**
 * 写入一个定位图形（含四周的白色分隔符）。
 * @param grid - 模块阵列。
 * @param size - 边长。
 * @param row - 定位图形左上角的行。
 * @param column - 定位图形左上角的列。
 */
function placeFinderPattern(grid: QrGrid, size: number, row: number, column: number): void {
  for (let offsetRow = -1; offsetRow <= 7; offsetRow += 1) {
    const targetRow = row + offsetRow
    if (targetRow < 0 || targetRow >= size) continue
    for (let offsetColumn = -1; offsetColumn <= 7; offsetColumn += 1) {
      const targetColumn = column + offsetColumn
      if (targetColumn < 0 || targetColumn >= size) continue
      const inRing = offsetRow >= 0 && offsetRow <= 6 && (offsetColumn === 0 || offsetColumn === 6)
      const inTopOrBottom = offsetColumn >= 0 && offsetColumn <= 6 && (offsetRow === 0 || offsetRow === 6)
      const inCore = offsetRow >= 2 && offsetRow <= 4 && offsetColumn >= 2 && offsetColumn <= 4
      setCell(grid, size, targetRow, targetColumn, inRing || inTopOrBottom || inCore ? QR_CELL_DARK : QR_CELL_LIGHT)
    }
  }
}

/**
 * 按版本表写入全部校正图形；已被定位/定时图形占用的位置跳过。
 * @param grid - 模块阵列。
 * @param size - 边长。
 * @param version - QR 版本号。
 */
function placeAlignmentPatterns(grid: QrGrid, size: number, version: number): void {
  const positions = requiredEntry(QR_ALIGNMENT_POSITIONS[version - 1], '校正图形')
  for (const row of positions) {
    for (const column of positions) {
      if (cellAt(grid, size, row, column) !== QR_CELL_UNSET) continue
      for (let offsetRow = -2; offsetRow <= 2; offsetRow += 1) {
        for (let offsetColumn = -2; offsetColumn <= 2; offsetColumn += 1) {
          const ring = Math.abs(offsetRow) === 2 || Math.abs(offsetColumn) === 2
          const dark = ring || (offsetRow === 0 && offsetColumn === 0)
          setCell(grid, size, row + offsetRow, column + offsetColumn, dark ? QR_CELL_DARK : QR_CELL_LIGHT)
        }
      }
    }
  }
}

/**
 * 写入第 6 行与第 6 列的黑白相间定时图形；已被占用的模块跳过。
 * @param grid - 模块阵列。
 * @param size - 边长。
 */
function placeTimingPatterns(grid: QrGrid, size: number): void {
  for (let index = 8; index < size - 8; index += 1) {
    const dark = index % 2 === 0 ? QR_CELL_DARK : QR_CELL_LIGHT
    if (cellAt(grid, size, index, 6) === QR_CELL_UNSET) setCell(grid, size, index, 6, dark)
    if (cellAt(grid, size, 6, index) === QR_CELL_UNSET) setCell(grid, size, 6, index, dark)
  }
}

/**
 * 写入格式信息与固定的深色模块。
 * @param grid - 模块阵列。
 * @param size - 边长。
 * @param mask - 掩码编号 0–7。
 * @param test - 为 true 时不写字面值（掩码评估阶段），模块位置照样占位。
 */
function placeFormatInfo(grid: QrGrid, size: number, mask: number, test: boolean): void {
  const bits = qrFormatBits((QR_ERROR_CORRECTION_M << 3) | mask)
  for (let index = 0; index < 15; index += 1) {
    const dark = !test && ((bits >>> index) & 1) === 1 ? QR_CELL_DARK : QR_CELL_LIGHT
    if (index < 6) setCell(grid, size, index, 8, dark)
    else if (index < 8) setCell(grid, size, index + 1, 8, dark)
    else setCell(grid, size, size - 15 + index, 8, dark)
  }
  for (let index = 0; index < 15; index += 1) {
    const dark = !test && ((bits >>> index) & 1) === 1 ? QR_CELL_DARK : QR_CELL_LIGHT
    if (index < 8) setCell(grid, size, 8, size - index - 1, dark)
    else if (index < 9) setCell(grid, size, 8, 15 - index - 1 + 1, dark)
    else setCell(grid, size, 8, 15 - index - 1, dark)
  }
  // 第 7 个校正图形的深色模块固定在 (size-8, 8)。
  setCell(grid, size, size - 8, 8, test ? QR_CELL_LIGHT : QR_CELL_DARK)
}

/**
 * 写入版本信息（版本 7 起）。
 * @param grid - 模块阵列。
 * @param size - 边长。
 * @param version - QR 版本号。
 * @param test - 为 true 时不写字面值（掩码评估阶段）。
 */
function placeVersionInfo(grid: QrGrid, size: number, version: number, test: boolean): void {
  const bits = qrVersionBits(version)
  for (let index = 0; index < 18; index += 1) {
    const dark = !test && ((bits >>> index) & 1) === 1 ? QR_CELL_DARK : QR_CELL_LIGHT
    setCell(grid, size, Math.floor(index / 3), index % 3 + size - 11, dark)
    setCell(grid, size, index % 3 + size - 11, Math.floor(index / 3), dark)
  }
}

/**
 * 掩码条件：`true` 表示该模块取反。
 * @param mask - 掩码编号 0–7。
 * @param row - 模块行号。
 * @param column - 模块列号。
 * @returns 是否需要取反。
 */
function maskCondition(mask: number, row: number, column: number): boolean {
  const product = row * column
  switch (mask) {
    case 0:
      return (row + column) % 2 === 0
    case 1:
      return row % 2 === 0
    case 2:
      return column % 3 === 0
    case 3:
      return (row + column) % 3 === 0
    case 4:
      return (Math.floor(row / 2) + Math.floor(column / 3)) % 2 === 0
    case 5:
      return (product % 2) + (product % 3) === 0
    case 6:
      return ((product % 2) + (product % 3)) % 2 === 0
    default:
      return ((product % 3) + ((row + column) % 2)) % 2 === 0
  }
}

/**
 * 按自右下角起、两列一组蛇形推进的顺序把码字写进矩阵的空模块，并套掩码。
 * @param grid - 已写好功能图形的模块阵列。
 * @param size - 边长。
 * @param codewords - 最终码字序列。
 * @param mask - 掩码编号。
 */
function placeData(grid: QrGrid, size: number, codewords: readonly number[], mask: number): void {
  let upward = true
  let row = size - 1
  let bitIndex = 7
  let byteIndex = 0
  for (let column = size - 1; column > 0; column -= 2) {
    if (column === 6) column -= 1
    for (;;) {
      for (let offset = 0; offset < 2; offset += 1) {
        const targetColumn = column - offset
        if (cellAt(grid, size, row, targetColumn) !== QR_CELL_UNSET) continue
        let dark = byteIndex < codewords.length
          && ((codewords[byteIndex] ?? 0) >>> bitIndex & 1) === 1
        if (maskCondition(mask, row, targetColumn)) dark = !dark
        setCell(grid, size, row, targetColumn, dark ? QR_CELL_DARK : QR_CELL_LIGHT)
        bitIndex -= 1
        if (bitIndex === -1) {
          byteIndex += 1
          bitIndex = 7
        }
      }
      row += upward ? -1 : 1
      if (row < 0 || row >= size) {
        row -= upward ? -1 : 1
        upward = !upward
        break
      }
    }
  }
}

/**
 * 掩码惩罚分：逐条对应 `qr 3.0.2`（手机 App 的 qr_flutter 依赖）的 `_lostPoint`，
 * 这样同一段文本在本实现与 App 里会得到逐模块相同的矩阵，便于用成熟实现互证。
 *
 * 四条规则：邻域同色、2×2 同色块、1:1:3:1:1 伪定位图形、深浅比例偏离 50%。
 * @param grid - 已套掩码的模块阵列（掩码评估阶段格式/版本信息为占位值）。
 * @param size - 边长。
 * @returns 惩罚分，越小越好。
 */
function qrPenaltyScore(grid: QrGrid, size: number): number {
  const dark = (row: number, column: number): boolean => cellAt(grid, size, row, column) === QR_CELL_DARK
  let score = 0
  // 规则 1：每个模块周围 8 格里有 5 个以上同色邻居。
  for (let row = 0; row < size; row += 1) {
    for (let column = 0; column < size; column += 1) {
      let same = 0
      for (let offsetRow = -1; offsetRow <= 1; offsetRow += 1) {
        const neighbourRow = row + offsetRow
        if (neighbourRow < 0 || neighbourRow >= size) continue
        for (let offsetColumn = -1; offsetColumn <= 1; offsetColumn += 1) {
          const neighbourColumn = column + offsetColumn
          if (neighbourColumn < 0 || neighbourColumn >= size) continue
          if (offsetRow === 0 && offsetColumn === 0) continue
          if (dark(row, column) === dark(neighbourRow, neighbourColumn)) same += 1
        }
      }
      if (same > 5) score += 3 + same - 5
    }
  }
  // 规则 2：2×2 同色块。
  for (let row = 0; row < size - 1; row += 1) {
    for (let column = 0; column < size - 1; column += 1) {
      const count = Number(dark(row, column)) + Number(dark(row + 1, column))
        + Number(dark(row, column + 1)) + Number(dark(row + 1, column + 1))
      if (count === 0 || count === 4) score += 3
    }
  }
  // 规则 3：1:1:3:1:1 的伪定位图形（横竖各扫一遍）。
  for (let row = 0; row < size; row += 1) {
    for (let column = 0; column < size - 6; column += 1) {
      if (dark(row, column) && !dark(row, column + 1) && dark(row, column + 2)
        && dark(row, column + 3) && dark(row, column + 4) && !dark(row, column + 5) && dark(row, column + 6)) {
        score += 40
      }
    }
  }
  for (let column = 0; column < size; column += 1) {
    for (let row = 0; row < size - 6; row += 1) {
      if (dark(row, column) && !dark(row + 1, column) && dark(row + 2, column)
        && dark(row + 3, column) && dark(row + 4, column) && !dark(row + 5, column) && dark(row + 6, column)) {
        score += 40
      }
    }
  }
  // 规则 4：深色比例偏离 50%（按参考实现折算成同一量纲）。
  let darkCount = 0
  for (let row = 0; row < size; row += 1) {
    for (let column = 0; column < size; column += 1) {
      if (dark(row, column)) darkCount += 1
    }
  }
  return score + Math.abs((100 * darkCount) / size / size - 50) / 5 * 10
}

/**
 * 按给定掩码构造一张模块阵列。
 * @param version - QR 版本号。
 * @param codewords - 最终码字序列。
 * @param mask - 掩码编号。
 * @param test - 为 true 时不写字面格式/版本信息，用于掩码评估。
 * @returns 模块阵列；交付前所有单元都必须写过（{@link encodeQrMatrix} 会检查）。
 */
function qrBuildGrid(version: number, codewords: readonly number[], mask: number, test: boolean): QrGrid {
  const size = version * 4 + 17
  const grid = new Uint8Array(size * size)
  placeFinderPattern(grid, size, 0, 0)
  placeFinderPattern(grid, size, size - 7, 0)
  placeFinderPattern(grid, size, 0, size - 7)
  placeAlignmentPatterns(grid, size, version)
  placeTimingPatterns(grid, size)
  placeFormatInfo(grid, size, mask, test)
  if (version >= 7) placeVersionInfo(grid, size, version, test)
  placeData(grid, size, codewords, mask)
  return grid
}

/**
 * 生成一段文本的二维码模块矩阵。
 *
 * 版本按内容自动取最小可容纳的 1–10；掩码在 8 种里取惩罚分最低的一种，
 * 与 `qr 3.0.2` 的选法逐模块一致（由 `apps/remote-host/scripts/qr-selfcheck.ts` 对照）。
 * @param text - 待编码文本（配对链接）。
 * @returns 矩阵、版本与掩码。
 * @throws 内容超过版本 10 的 M 级容量时抛出。
 */
export function encodeQrMatrix(text: string): QrMatrix {
  const { version, blocks } = qrSelectVersion(Buffer.byteLength(text, 'utf8'))
  const codewords = qrCodewords(text, version, blocks)
  let bestMask = 0
  let bestScore = Number.POSITIVE_INFINITY
  for (let mask = 0; mask < 8; mask += 1) {
    const score = qrPenaltyScore(qrBuildGrid(version, codewords, mask, true), version * 4 + 17)
    if (score < bestScore) {
      bestScore = score
      bestMask = mask
    }
  }
  const size = version * 4 + 17
  const grid = qrBuildGrid(version, codewords, bestMask, false)
  const modules: boolean[][] = []
  for (let row = 0; row < size; row += 1) {
    const cells: boolean[] = []
    for (let column = 0; column < size; column += 1) {
      const cell = cellAt(grid, size, row, column)
      if (cell === QR_CELL_UNSET) throw new Error(`二维码矩阵在 (${row}, ${column}) 没有写完。`)
      cells.push(cell === QR_CELL_DARK)
    }
    modules.push(cells)
  }
  return { version, size, mask: bestMask, modules }
}

/**
 * 把矩阵渲染成终端里的字符画。
 *
 * 每个字符单元覆盖「1 模块宽 × 2 模块高」：用半块字符 `▀`/`▄`/`█` 画深色模块，
 * 配白底黑字，常见等宽字体下模块接近正方形。四周留 4 模块安静区；每行首尾包
 * ANSI 颜色并在行尾复原，避免污染后续日志。
 * @param matrix - {@link encodeQrMatrix} 的结果。
 * @returns 多行文本，行间用 `\n` 分隔、末尾不带换行。
 */
export function renderTerminalQr(matrix: QrMatrix): string {
  const quiet = 4
  const total = matrix.size + quiet * 2
  const darkAt = (row: number, column: number): boolean => {
    const moduleRow = row - quiet
    const moduleColumn = column - quiet
    if (moduleRow < 0 || moduleRow >= matrix.size) return false
    if (moduleColumn < 0 || moduleColumn >= matrix.size) return false
    return matrix.modules[moduleRow]?.[moduleColumn] === true
  }
  const lines: string[] = []
  for (let row = 0; row < total; row += 2) {
    // 黑字白底：深色模块是黑色块，浅色模块与安静区保持白色。
    let line = '\u001b[30;47m'
    for (let column = 0; column < total; column += 1) {
      const top = darkAt(row, column)
      const bottom = darkAt(row + 1, column)
      line += top ? (bottom ? '█' : '▀') : (bottom ? '▄' : ' ')
    }
    lines.push(`${line}\u001b[0m`)
  }
  return lines.join('\n')
}
