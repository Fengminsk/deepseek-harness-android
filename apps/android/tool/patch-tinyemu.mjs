import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

/** Apply reviewed embedding changes to the exact pinned upstream source, rejecting drift. */
export async function patchTinyEmu(directory) {
  const edits = {
    'machine.h': [['typedef struct VirtMachine {\n', 'typedef struct VirtMachine {\n    BOOL power_off; /* Embedding owner observes shutdown without exiting Android. */\n']],
    'riscv_machine.c': [
      ['    VIRTIODevice *keyboard_dev;\n', '    VIRTIODevice *block_devices[MAX_DRIVE_DEVICE];\n    int block_device_count;\n    VIRTIODevice *keyboard_dev;\n'],
      ['        printf("\\nPower off.\\n");\n        exit(0);', '        s->common.power_off = TRUE;'],
      ['        (void)blk_dev;', '        s->block_devices[s->block_device_count++] = blk_dev;'],
      ['    /* XXX: stop all */\n    riscv_cpu_end(s->cpu_state);',
        '    /* This embedding creates only synchronous block and console devices. */\n    free(s->common.console_dev);\n    for (int i = 0; i < s->block_device_count; i++) free(s->block_devices[i]);\n    riscv_cpu_end(s->cpu_state);'],
    ],
    'riscv_cpu.c': [['#ifdef USE_GLOBAL_STATE\n    free(s);\n#endif', '#ifndef USE_GLOBAL_STATE\n    free(s);\n#endif']],
    'virtio.c': [
      ['    if (s1->req_in_progress)\n        return -1;',
        '    if (s1->req_in_progress)\n        return -1;\n    /* Guest descriptor lengths never control an unbounded host allocation. */\n    if (read_size < (int)sizeof(h) || write_size < 1 ||\n        read_size > 1048576 || write_size > 1048577) return -1;'],
      ['    if (queue_idx == 1) {\n        /* send to console */',
        '    if (queue_idx == 1) {\n        if (read_size < 0 || read_size > 65536) return -1;\n        /* send to console */'],
    ],
  }
  for (const [name, replacements] of Object.entries(edits)) {
    const path = join(directory, name)
    let source = (await readFile(path, 'utf8')).replaceAll('\r\n', '\n')
    for (const [before, after] of replacements) {
      if (source.split(before).length !== 2) throw new Error(`TinyEMU patch input differs: ${name}`)
      source = source.replace(before, after)
    }
    await writeFile(path, source)
  }
}
