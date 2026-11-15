/**
 * 配对二维码自检：证明 `../src/pairing-qr.ts` 里的纯 Node QR 编码与终端渲染是对的。
 *
 * 运行：`pnpm exec tsx apps/remote-host/scripts/qr-selfcheck.ts`
 * 退出码：全部通过 0，任一断言失败 1。脚本不写文件、不开端口、不联网。
 *
 * 为什么值得单独校验：二维码没有「大概对」——错一个模块就是一张扫不出来的图；
 * 而配对二维码里装着一次性令牌，用户只会照着日志试一次。
 *
 * 四层校验：
 * 1. **已知答案（KAT）**：14 段文本的矩阵摘要必须等于期望值。期望值由手机 App 已在
 *    用的 `qr 3.0.2`（`qr_flutter` 的依赖）生成，逐模块对照；同一组输入另用
 *    `qrcode@1.5.4` 复核过数据区（单字节段输入的数据位逐位一致，只有掩码选择不同，
 *    因为两家选掩码的惩罚函数不同；两种掩码都合法）。覆盖版本 1–10 与三种真实
 *    配对链接形态。
 * 2. **结构**：定位图形/分隔符/定时图形/固定深色模块、格式信息（BCH 校验、纠错等级
 *    M、掩码号）、版本信息（版本 7 起）、矩阵尺寸。
 * 3. **独立回读**：按规范的蛇形顺序取数据位、去掩码、拆 RS 块，验 Reed-Solomon 综合
 *    为零，再把字节段解码回原文。它验的是编码侧（分块/交错/纠错码字），而不是只验
 *    「自己和自己一致」。
 * 4. **渲染**：安静区、行宽、字符集、每行 ANSI 复位。
 *
 * @module @deepseek-ai/dsh-remote-host/scripts/qr-selfcheck
 */

import { createHash } from 'node:crypto'
import { writePairingQr } from '../src/index.ts'
import { encodeQrMatrix, renderTerminalQr, type QrMatrix } from '../src/pairing-qr.ts'

/** 纠错等级 M 在 QR 格式信息里的编码值（规范：L=1、M=0、Q=3、H=2）。 */
const ERROR_CORRECTION_M = 0

/** 格式信息的生成多项式 G15。 */
const FORMAT_GENERATOR = 0b10100110111

/** 格式信息落盘前异或的固定掩码。 */
const FORMAT_MASK = 0b101010000010010

/** 版本信息的生成多项式 G18。 */
const VERSION_GENERATOR = 0b1111100100101

/**
 * 版本 1–10、纠错等级 M 的 RS 分块表：`[块数, 每块总码字, 每块数据码字, …]`。
 * 与 `../src/index.ts` 是同一张表；表写错时 KAT 摘要会先失败。
 */
const RS_BLOCKS_M: readonly (readonly number[])[] = [
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

/** 版本 1–10 的校正图形中心坐标。 */
const ALIGNMENT_POSITIONS: readonly (readonly number[])[] = [
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

/** 一段文本的矩阵摘要断言。 */
interface KnownAnswer {
  /** 用例说明。 */
  readonly name: string
  /** 待编码文本。 */
  readonly text: string
  /** 期望版本号。 */
  readonly version: number
  /** 期望矩阵边长。 */
  readonly size: number
  /** 期望掩码编号。 */
  readonly mask: number
  /** 期望摘要：`sha256("版本|掩码|边长\n逐行 0/1")`。 */
  readonly digest: string
}

/** 覆盖版本 1–10 与真实配对链接形态的已知答案。 */
const KNOWN_ANSWERS: readonly KnownAnswer[] = [
  {
    name: '真实链接 · 局域网 IP（版本 8、掩码 7）',
    text: `wss://192.168.5.21:4777#instance=${'a'.repeat(64)}&token=${'b'.repeat(43)}`,
    version: 8,
    size: 49,
    mask: 7,
    digest: '31878111a1d3b20592581be8b9d5ee247efec38eb7d0c3c3e5ee379e80fef7e2',
  },
  {
    name: '真实链接 · 域名 + 8443（版本 8、掩码 2）',
    text: `wss://dsh.example.com:8443#instance=${'c'.repeat(64)}&token=${'d'.repeat(43)}`,
    version: 8,
    size: 49,
    mask: 2,
    digest: '3d5c70c5a1c77daa3cdf9d48b4ba05c892981f6058979533fcdb10d22191eaf6',
  },
  {
    name: '真实链接 · 长域名（版本 9、掩码 3）',
    text: `wss://remote.my-company.example.com:8443#instance=${'e'.repeat(64)}&token=${'f'.repeat(43)}`,
    version: 9,
    size: 53,
    mask: 3,
    digest: 'b23b0384e3531c2512198936fccf4050025b0f0f4d186799e1e493af360b9df2',
  },
  {
    name: '字节模式 · 5 字节（版本 1、掩码 2）',
    text: 'HELLO',
    version: 1,
    size: 21,
    mask: 2,
    digest: '8b7fe230b409327249a2f1fb7bfcb8654507a1b6b8273f6c637315ddf5e8e2ed',
  },
  {
    name: '版本 1 容量边界 · 1 字节（掩码 3）',
    text: 'y',
    version: 1,
    size: 21,
    mask: 3,
    digest: '6e18cb15473da8a855f657b0632e3717d4af15c32aba92fdadc7a240f59307c4',
  },
  {
    name: '版本 2 · 26 字节（掩码 0）',
    text: 'x'.repeat(26),
    version: 2,
    size: 25,
    mask: 0,
    digest: '664dd2e1d573617ef4f9799030203ff320950520e8ec350834a55de57f4a6349',
  },
  {
    name: '版本 3 · 40 字节（掩码 0）',
    text: 'x'.repeat(40),
    version: 3,
    size: 29,
    mask: 0,
    digest: '2f29438b8104ba526e67f9474cc57c8240c5acd1d155756a3f4c3eb3b7abb2dd',
  },
  {
    name: '版本 4 · 62 字节（掩码 0）',
    text: 'x'.repeat(62),
    version: 4,
    size: 33,
    mask: 0,
    digest: 'a199f969f5ce8f8425ac97d9c1f77a110f8d549a8e89f43a11a28e5175007912',
  },
  {
    name: '版本 5 · 80 字节（掩码 2）',
    text: 'x'.repeat(80),
    version: 5,
    size: 37,
    mask: 2,
    digest: 'f795433c33498b1896fcd38b42344c25f156ccc2a5a512eb530e942e6c4d96bf',
  },
  {
    name: '版本 6 · 106 字节（掩码 3）',
    text: 'x'.repeat(106),
    version: 6,
    size: 41,
    mask: 3,
    digest: '615d14b901a6da9e1640794237c0743a43f669bf9246955a36afd5d6a01ba700',
  },
  {
    name: '版本 7 · 120 字节（掩码 2）',
    text: 'x'.repeat(120),
    version: 7,
    size: 45,
    mask: 2,
    digest: '4b8dd91b746952e4a7db17f96e2c4d79fd06482f1564326e51b084a21c5284a1',
  },
  {
    name: '版本 8 · 150 字节（掩码 2）',
    text: 'x'.repeat(150),
    version: 8,
    size: 49,
    mask: 2,
    digest: '1e4a2bc02bdd36b6fb7269940668bf8790d4012d67a3f078d70164808eab69f2',
  },
  {
    name: '版本 9 · 180 字节（掩码 2）',
    text: 'x'.repeat(180),
    version: 9,
    size: 53,
    mask: 2,
    digest: 'fb279d28d36b9891ceee033fa3bc1c38d90be12b9b3801dd5d70983248adfe4c',
  },
  {
    name: '版本 10 · 210 字节（掩码 2）',
    text: 'x'.repeat(210),
    version: 10,
    size: 57,
    mask: 2,
    digest: '63338028246008d901b3de684d6dc1bd256a1255967f3cf47adc43fdc016ee2e',
  },
]

/** 一条断言失败。 */
class SelfCheckFailure extends Error {}

/**
 * 断言为真。
 * @param condition - 断言条件。
 * @param message - 失败时写进输出的中文说明。
 */
function check(condition: boolean, message: string): void {
  if (!condition) throw new SelfCheckFailure(message)
}

/**
 * 取一个必然存在的表项。
 * @param value - 表项读取结果。
 * @param name - 表名，写进失败原因。
 * @returns 该表项。
 */
function tableEntry<T>(value: T | undefined, name: string): T {
  if (value === undefined) throw new SelfCheckFailure(`二维码${name}表缺少对应项。`)
  return value
}

/**
 * 读取矩阵单元。
 * @param matrix - 待读取的矩阵。
 * @param row - 行号。
 * @param column - 列号。
 * @returns 是否深色。
 */
function matrixCell(matrix: QrMatrix, row: number, column: number): boolean {
  return matrix.modules[row]?.[column] === true
}

/**
 * 计算矩阵摘要；KAT 期望值就是这个摘要。
 * @param matrix - 待摘要的矩阵。
 * @returns 十六进制 sha256。
 */
function matrixDigest(matrix: QrMatrix): string {
  const rows = matrix.modules.map(row => row.map(dark => (dark ? '1' : '0')).join('')).join('\n')
  return createHash('sha256').update(`${matrix.version}|${matrix.mask}|${matrix.size}\n${rows}`).digest('hex')
}

/**
 * 整数的有效位数。
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
 * 用 BCH 生成多项式除一遍，判断余数是否为 0。
 * @param bits - 待校验的码字。
 * @param generator - 生成多项式。
 * @returns 是否通过校验。
 */
function bchIsValid(bits: number, generator: number): boolean {
  let remainder = bits
  while (bitLength(remainder) - bitLength(generator) >= 0) {
    remainder ^= generator << (bitLength(remainder) - bitLength(generator))
  }
  return remainder === 0
}

/**
 * 读取矩阵里的 15 位格式信息（两份拷贝必须相同）。
 * @param matrix - 待校验矩阵。
 * @returns 去掉固定掩码后的 15 位格式信息。
 */
function readFormatInfo(matrix: QrMatrix): number {
  const size = matrix.size
  const dark = (row: number, column: number): number => (matrixCell(matrix, row, column) ? 1 : 0)
  let first = 0
  for (let index = 0; index < 15; index += 1) {
    if (index < 6) first |= dark(index, 8) << index
    else if (index < 8) first |= dark(index + 1, 8) << index
    else first |= dark(size - 15 + index, 8) << index
  }
  let second = 0
  for (let index = 0; index < 15; index += 1) {
    if (index < 8) second |= dark(8, size - index - 1) << index
    else if (index < 9) second |= dark(8, 15 - index - 1 + 1) << index
    else second |= dark(8, 15 - index - 1) << index
  }
  check(first === second, `格式信息两份拷贝不一致（${first} vs ${second}）`)
  return first ^ FORMAT_MASK
}

/**
 * 读取矩阵里的 18 位版本信息（版本 7 起才有，两份拷贝必须相同）。
 * @param matrix - 待校验矩阵。
 * @returns 18 位版本信息。
 */
function readVersionInfo(matrix: QrMatrix): number {
  const size = matrix.size
  const dark = (row: number, column: number): number => (matrixCell(matrix, row, column) ? 1 : 0)
  let first = 0
  for (let index = 0; index < 18; index += 1) {
    first |= dark(Math.floor(index / 3), index % 3 + size - 11) << index
  }
  let second = 0
  for (let index = 0; index < 18; index += 1) {
    second |= dark(index % 3 + size - 11, Math.floor(index / 3)) << index
  }
  check(first === second, `版本信息两份拷贝不一致（${first} vs ${second}）`)
  return first
}

/**
 * 重新推导功能图形占用的模块（定位图形、分隔符、校正图形、定时图形、格式/版本
 * 信息、固定深色模块）。回读数据位时必须跳过这些位置。
 * @param version - QR 版本号。
 * @returns `row:column` 组成的集合。
 */
function functionModules(version: number): Set<string> {
  const size = version * 4 + 17
  const positions = new Set<string>()
  const add = (row: number, column: number): void => {
    if (row < 0 || row >= size || column < 0 || column >= size) return
    positions.add(`${row}:${column}`)
  }
  for (const origin of finderOrigins(size)) {
    for (let row = -1; row <= 7; row += 1) {
      for (let column = -1; column <= 7; column += 1) add(origin[0] + row, origin[1] + column)
    }
  }
  const alignment = tableEntry(ALIGNMENT_POSITIONS[version - 1], '校正图形')
  for (const row of alignment) {
    for (const column of alignment) {
      if (positions.has(`${row}:${column}`)) continue
      for (let offsetRow = -2; offsetRow <= 2; offsetRow += 1) {
        for (let offsetColumn = -2; offsetColumn <= 2; offsetColumn += 1) add(row + offsetRow, column + offsetColumn)
      }
    }
  }
  for (let index = 8; index < size - 8; index += 1) {
    add(index, 6)
    add(6, index)
  }
  for (let index = 0; index < 15; index += 1) {
    if (index < 6) add(index, 8)
    else if (index < 8) add(index + 1, 8)
    else add(size - 15 + index, 8)
    if (index < 8) add(8, size - index - 1)
    else if (index < 9) add(8, 15 - index - 1 + 1)
    else add(8, 15 - index - 1)
  }
  add(size - 8, 8)
  if (version >= 7) {
    for (let index = 0; index < 18; index += 1) {
      add(Math.floor(index / 3), index % 3 + size - 11)
      add(index % 3 + size - 11, Math.floor(index / 3))
    }
  }
  return positions
}

/**
 * 三个定位图形左上角的坐标。
 * @param size - 矩阵边长。
 * @returns `[行, 列]` 三元组。
 */
function finderOrigins(size: number): readonly (readonly [number, number])[] {
  return [[0, 0], [size - 7, 0], [0, size - 7]]
}

/**
 * 掩码条件（与规范一致）；`true` 表示该模块被取反。
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

/** GF(256) 的指数表与对数表，用于 Reed-Solomon 综合。 */
const GALOIS = createGaloisTables()

/**
 * 按本原多项式 x^8 + x^4 + x^3 + x^2 + 1 建表。
 * @returns 指数表（512 项）与对数表（256 项）。
 */
function createGaloisTables(): { readonly exp: Uint8Array; readonly log: Uint8Array } {
  const exp = new Uint8Array(512)
  const log = new Uint8Array(256)
  let value = 1
  for (let index = 0; index < 255; index += 1) {
    exp[index] = value
    log[value] = index
    value <<= 1
    if ((value & 0x100) !== 0) value ^= 0x11d
  }
  for (let index = 255; index < 512; index += 1) exp[index] = exp[index - 255] ?? 0
  return { exp, log }
}

/**
 * GF(256) 乘法。
 * @param left - 第一个乘数。
 * @param right - 第二个乘数。
 * @returns 乘积。
 */
function galoisMultiply(left: number, right: number): number {
  if (left === 0 || right === 0) return 0
  return GALOIS.exp[(GALOIS.log[left] ?? 0) + (GALOIS.log[right] ?? 0)] ?? 0
}

/**
 * 把版本号展开成逐块码字数。
 * @param version - QR 版本号。
 * @returns 逐块 `{ totalCount, dataCount }`。
 */
function expandBlocks(version: number): { totalCount: number; dataCount: number }[] {
  const table = tableEntry(RS_BLOCKS_M[version - 1], 'RS 分块')
  const blocks: { totalCount: number; dataCount: number }[] = []
  for (let index = 0; index < table.length; index += 3) {
    const count = tableEntry(table[index], 'RS 分块')
    const totalCount = tableEntry(table[index + 1], 'RS 分块')
    const dataCount = tableEntry(table[index + 2], 'RS 分块')
    for (let repeat = 0; repeat < count; repeat += 1) blocks.push({ totalCount, dataCount })
  }
  return blocks
}

/**
 * 独立回读矩阵：取数据位、去掩码、拆块、验 RS 综合、解码字节段。
 * @param matrix - 已生成的矩阵。
 * @returns 解码出的原始文本。
 */
function decodeMatrix(matrix: QrMatrix): string {
  const size = matrix.size
  const functions = functionModules(matrix.version)
  const blocks = expandBlocks(matrix.version)
  const totalCodewords = blocks.reduce((total, block) => total + block.totalCount, 0)
  const needed = totalCodewords * 8
  const bits: number[] = []
  // 与编码侧相同的蛇形推进：右下角起、两列一组、跳过第 6 列。
  let upward = true
  let row = size - 1
  for (let column = size - 1; column > 0 && bits.length < needed; column -= 2) {
    if (column === 6) column -= 1
    for (;;) {
      for (let offset = 0; offset < 2 && bits.length < needed; offset += 1) {
        const targetColumn = column - offset
        if (functions.has(`${row}:${targetColumn}`)) continue
        const masked = matrixCell(matrix, row, targetColumn)
        const data = masked !== maskCondition(matrix.mask, row, targetColumn)
        bits.push(data ? 1 : 0)
      }
      row += upward ? -1 : 1
      if (row < 0 || row >= size) {
        row -= upward ? -1 : 1
        upward = !upward
        break
      }
    }
  }
  check(bits.length === needed, `回读的数据位不足：${bits.length} / ${needed}`)
  const codewords: number[] = []
  for (let index = 0; index < bits.length; index += 8) {
    let byte = 0
    for (let offset = 0; offset < 8; offset += 1) byte = (byte << 1) | (bits[index + offset] ?? 0)
    codewords.push(byte)
  }
  // 拆块：数据码字按块交错在前，纠错码字按块交错在后。
  const dataBlocks: number[][] = blocks.map(() => [])
  const errorBlocks: number[][] = blocks.map(() => [])
  let offset = 0
  const maxData = Math.max(...blocks.map(block => block.dataCount))
  for (let index = 0; index < maxData; index += 1) {
    for (let blockIndex = 0; blockIndex < blocks.length; blockIndex += 1) {
      const block = tableEntry(blocks[blockIndex], 'RS 分块')
      if (index < block.dataCount) {
        const target = tableEntry(dataBlocks[blockIndex], '数据块')
        target.push(codewords[offset] ?? 0)
        offset += 1
      }
    }
  }
  const maxError = Math.max(...blocks.map(block => block.totalCount - block.dataCount))
  for (let index = 0; index < maxError; index += 1) {
    for (let blockIndex = 0; blockIndex < blocks.length; blockIndex += 1) {
      const block = tableEntry(blocks[blockIndex], 'RS 分块')
      if (index < block.totalCount - block.dataCount) {
        const target = tableEntry(errorBlocks[blockIndex], '纠错块')
        target.push(codewords[offset] ?? 0)
        offset += 1
      }
    }
  }
  check(offset === totalCodewords, `拆块后码字数不一致：${offset} / ${totalCodewords}`)
  // Reed-Solomon 综合：整块（数据 + 纠错）在 α^0 … α^(ec-1) 处的取值必须全为 0。
  for (let blockIndex = 0; blockIndex < blocks.length; blockIndex += 1) {
    const block = tableEntry(blocks[blockIndex], 'RS 分块')
    const data = tableEntry(dataBlocks[blockIndex], '数据块')
    const error = tableEntry(errorBlocks[blockIndex], '纠错块')
    const codewordBlock = [...data, ...error]
    const errorCount = block.totalCount - block.dataCount
    for (let power = 0; power < errorCount; power += 1) {
      let value = 0
      for (const byte of codewordBlock) value = galoisMultiply(value, GALOIS.exp[power] ?? 0) ^ byte
      check(value === 0, `第 ${blockIndex + 1} 块的 RS 综合在 α^${power} 处不为 0（${value}）`)
    }
  }
  // 解码字节段：模式 4 位 + 计数（版本 10 起 16 位）+ 字节；数据跨块时按块顺序拼接。
  const payload = dataBlocks.flat()
  let cursor = 0
  const read = (length: number): number => {
    let value = 0
    for (let index = 0; index < length; index += 1) {
      const byte = payload[Math.floor(cursor / 8)] ?? 0
      value = (value << 1) | ((byte >>> (7 - (cursor % 8))) & 1)
      cursor += 1
    }
    return value
  }
  const mode = read(4)
  check(mode === 0b0100, `回读的模式不是字节模式：${mode.toString(2)}`)
  const length = read(matrix.version < 10 ? 8 : 16)
  const bytes: number[] = []
  for (let index = 0; index < length; index += 1) bytes.push(read(8))
  return Buffer.from(bytes).toString('utf8')
}

/**
 * 校验一张矩阵的结构与回读结果。
 * @param matrix - 已生成的矩阵。
 * @param text - 期望能回读出来的原文。
 */
function verifyMatrix(matrix: QrMatrix, text: string): void {
  const size = matrix.size
  check(size === matrix.version * 4 + 17, `矩阵边长与版本不符：${size} / ${matrix.version}`)
  check(matrix.modules.length === size, '矩阵行数与边长不符')
  check(matrix.modules.every(row => row.length === size), '矩阵列数与边长不符')
  // 定位图形与分隔符：三个角上 7×7 的图形（含一圈白色分隔符）。
  for (const origin of finderOrigins(size)) {
    for (let offsetRow = -1; offsetRow <= 7; offsetRow += 1) {
      for (let offsetColumn = -1; offsetColumn <= 7; offsetColumn += 1) {
        const row = origin[0] + offsetRow
        const column = origin[1] + offsetColumn
        if (row < 0 || row >= size || column < 0 || column >= size) continue
        const ring = offsetRow >= 0 && offsetRow <= 6 && (offsetColumn === 0 || offsetColumn === 6)
        const topOrBottom = offsetColumn >= 0 && offsetColumn <= 6 && (offsetRow === 0 || offsetRow === 6)
        const core = offsetRow >= 2 && offsetRow <= 4 && offsetColumn >= 2 && offsetColumn <= 4
        check(matrixCell(matrix, row, column) === (ring || topOrBottom || core),
          `定位图形在 (${row}, ${column}) 与规范不符`)
      }
    }
  }
  // 定时图形：第 6 行与第 6 列黑白相间。
  for (let index = 8; index < size - 8; index += 1) {
    check(matrixCell(matrix, 6, index) === (index % 2 === 0), `第 6 行定时图形在列 ${index} 不符`)
    check(matrixCell(matrix, index, 6) === (index % 2 === 0), `第 6 列定时图形在行 ${index} 不符`)
  }
  // 固定深色模块。
  check(matrixCell(matrix, size - 8, 8), '固定深色模块 (size-8, 8) 不是深色')
  // 格式信息：BCH 校验通过、纠错等级为 M、掩码号与矩阵一致。
  const format = readFormatInfo(matrix)
  check(bchIsValid(format, FORMAT_GENERATOR), `格式信息 BCH 校验失败：${format.toString(2)}`)
  const formatData = format >>> 10
  check((formatData >>> 3) === ERROR_CORRECTION_M, `格式信息里的纠错等级不是 M：${formatData >>> 3}`)
  check((formatData & 0b111) === matrix.mask, `格式信息里的掩码号与矩阵不一致：${formatData & 0b111} vs ${matrix.mask}`)
  // 版本信息：版本 7 起才有。
  if (matrix.version >= 7) {
    const versionBits = readVersionInfo(matrix)
    check(bchIsValid(versionBits, VERSION_GENERATOR), `版本信息 BCH 校验失败：${versionBits.toString(2)}`)
    check((versionBits >>> 12) === matrix.version, `版本信息里的版本号不一致：${versionBits >>> 12}`)
  }
  // 独立回读。
  const decoded = decodeMatrix(matrix)
  check(decoded === text, `回读文本与原文不一致：${JSON.stringify(decoded)}`)
}

/**
 * 校验终端渲染：安静区、行宽、字符集、每行 ANSI 复位。
 * @param matrix - 已生成的矩阵。
 */
function verifyRender(matrix: QrMatrix): void {
  const lines = renderTerminalQr(matrix).split('\n')
  const stripped = lines.map(line => line.replace(/\u001b\[[0-9;]*m/gu, ''))
  const width = matrix.size + 8
  check(stripped.every(line => line.length === width), `渲染行宽不是 ${width}`)
  check((stripped[0] ?? '').trim() === '' && (stripped[1] ?? '').trim() === '', '顶部安静区不足 4 个模块')
  check((stripped[stripped.length - 1] ?? '').trim() === '', '底部安静区不足 4 个模块')
  check(stripped.every(line => line[0] === ' ' && line[line.length - 1] === ' '), '左右安静区不足 4 个模块')
  const allowed = new Set([' ', '▀', '▄', '█'])
  check(stripped.every(line => [...line].every(character => allowed.has(character))), '渲染里出现了不认识的字符')
  check(lines.every(line => line.startsWith('\u001b[30;47m') && line.endsWith('\u001b[0m')),
    '每行都要以 ANSI 颜色开头并在行尾复位')
}

/**
 * 截获一次 stderr 写入。
 * @param pairUrl - 打印用的配对链接。
 * @param isTerminal - 是否把 stderr 伪装成终端。
 * @returns 这段代码实际写到 stderr 的文本。
 */
function capturePairingQrOutput(pairUrl: string, isTerminal: boolean): string {
  const chunks: string[] = []
  const writeDescriptor = Object.getOwnPropertyDescriptor(process.stderr, 'write')
  const ttyDescriptor = Object.getOwnPropertyDescriptor(process.stderr, 'isTTY')
  const capture = (chunk: string | Uint8Array): boolean => {
    chunks.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8'))
    return true
  }
  // 自检跑在管道上（没有终端）；这里只改本次进程里 stderr 对象自己的属性来模拟终端。
  Object.defineProperty(process.stderr, 'write', { value: capture, configurable: true, writable: true })
  Object.defineProperty(process.stderr, 'isTTY', { value: isTerminal, configurable: true, writable: true })
  try {
    writePairingQr(pairUrl)
  } finally {
    Object.defineProperty(process.stderr, 'write',
      writeDescriptor ?? { value: process.stderr.write, configurable: true, writable: true })
    Object.defineProperty(process.stderr, 'isTTY',
      ttyDescriptor ?? { value: undefined, configurable: true, writable: true })
  }
  return chunks.join('')
}

/**
 * 校验终端打印分支：终端里给二维码 + 明文链接，重定向（日志文件）时什么都不写。
 * @param pairUrl - 打印用的配对链接。
 */
function verifyTerminalOutput(pairUrl: string): void {
  const terminal = capturePairingQrOutput(pairUrl, true)
  check(terminal.includes(pairUrl), '终端输出里没有明文配对链接')
  check(terminal.includes('\u001b[30;47m'), '终端输出里没有二维码颜色块')
  check(terminal.includes('▀') || terminal.includes('▄') || terminal.includes('█'), '终端输出里没有二维码字符画')
  const redirected = capturePairingQrOutput(pairUrl, false)
  check(redirected === '', `非终端时不该写 stderr，实际写了 ${redirected.length} 个字符`)
}

/**
 * 跑全部断言。
 * @returns 通过的断言条数。
 */
function main(): number {
  let checks = 0
  for (const answer of KNOWN_ANSWERS) {
    const matrix = encodeQrMatrix(answer.text)
    check(matrix.version === answer.version, `${answer.name}：版本应为 ${answer.version}，实际 ${matrix.version}`)
    check(matrix.size === answer.size, `${answer.name}：边长应为 ${answer.size}，实际 ${matrix.size}`)
    check(matrix.mask === answer.mask, `${answer.name}：掩码应为 ${answer.mask}，实际 ${matrix.mask}`)
    check(matrixDigest(matrix) === answer.digest, `${answer.name}：矩阵摘要与期望值不一致`)
    verifyMatrix(matrix, answer.text)
    verifyRender(matrix)
    checks += 1
    console.log(`PASS  ${answer.name}：v${matrix.version} / ${matrix.size}×${matrix.size} / mask ${matrix.mask}`)
  }
  // 超长输入必须显式失败，而不是悄悄截断。
  let rejected = false
  try {
    encodeQrMatrix('x'.repeat(1000))
  } catch {
    rejected = true
  }
  check(rejected, '超过版本 10 容量的输入没有失败')
  checks += 1
  console.log('PASS  超过版本 10 容量的输入会失败，没有静默截断')
  verifyTerminalOutput(`wss://192.168.5.21:4777#instance=${'a'.repeat(64)}&token=${'b'.repeat(43)}`)
  checks += 1
  console.log('PASS  终端打印二维码与明文链接；日志重定向时不往 stderr 写块字符')
  return checks
}

try {
  const checks = main()
  console.log('')
  console.log(`PASS  ${checks}/${checks} 项全部通过（矩阵 KAT + 结构 + 独立回读 + 渲染）`)
  process.exitCode = 0
} catch (error) {
  console.log('')
  console.log(`FAIL  配对二维码自检失败：${error instanceof Error ? error.message : String(error)}`)
  process.exitCode = 1
}
