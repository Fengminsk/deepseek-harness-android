// `publicOrigin` 归一化的零依赖自检：防止 WHATWG URL 把显式 `:443` 当默认端口省略，
// 进而生成端口错误的配对链接（App 缺省按 4777 补全会连到错误端口）。
//
// 运行：node --import tsx/esm apps/remote-host/scripts/public-origin-selfcheck.ts

import { normalizePublicOrigin } from '../src/index.ts'

interface Case {
  readonly name: string
  readonly input: string
  readonly expected?: string
  readonly throws?: RegExp
}

const cases: readonly Case[] = [
  { name: '未配置返回空串', input: '', expected: '' },
  { name: '普通 wss 保留默认端口省略', input: 'wss://pc.example.com', expected: 'wss://pc.example.com' },
  { name: '显式 443 保留端口', input: 'wss://pc.example.com:443', expected: 'wss://pc.example.com:443' },
  { name: '显式 443 带尾斜杠保留端口', input: 'wss://pc.example.com:443/', expected: 'wss://pc.example.com:443' },
  { name: '非默认端口原样保留', input: 'wss://pc.example.com:8443', expected: 'wss://pc.example.com:8443' },
  { name: 'IPv6 显式 443 保留端口', input: 'wss://[::1]:443', expected: 'wss://[::1]:443' },
  { name: '大写主机名归一化', input: 'WSS://PC.Example.COM:443', expected: 'wss://pc.example.com:443' },
  { name: '裸 443 无主机名仍非法', input: 'wss://:443', throws: /不是合法 URL/u },
  { name: 'https 被拒绝', input: 'https://pc.example.com', throws: /必须是 wss/u },
  { name: '带路径被拒绝', input: 'wss://pc.example.com:443/app', throws: /路径/u },
  { name: '带查询串被拒绝', input: 'wss://pc.example.com?x=1', throws: /查询串/u },
  { name: '带账号信息被拒绝', input: 'wss://user:pass@pc.example.com', throws: /用户名/u },
  { name: '空白被拒绝', input: 'wss://pc example.com', throws: /空白/u },
]

let passed = 0
const failures: string[] = []

for (const testCase of cases) {
  try {
    const actual = normalizePublicOrigin(testCase.input)
    if (testCase.expected !== undefined && actual === testCase.expected) {
      passed += 1
      console.log(`PASS  ${testCase.name}：${JSON.stringify(testCase.input)} → ${JSON.stringify(actual)}`)
      continue
    }
    failures.push(`${testCase.name}：期望 ${JSON.stringify(testCase.expected)}，实际 ${JSON.stringify(actual)}`)
  } catch (error) {
    if (testCase.throws !== undefined && error instanceof Error && testCase.throws.test(error.message)) {
      passed += 1
      console.log(`PASS  ${testCase.name}：按预期抛错「${error.message}」`)
      continue
    }
    failures.push(`${testCase.name}：抛出了非预期错误 ${error instanceof Error ? error.message : String(error)}`)
  }
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`FAIL  ${failure}`)
  console.error(`\nFAIL  ${failures.length}/${cases.length} 项失败`)
  process.exitCode = 1
} else {
  console.log(`\nPASS  ${passed}/${cases.length} 项全部通过（显式 443 保留 + 合法性校验）`)
}
