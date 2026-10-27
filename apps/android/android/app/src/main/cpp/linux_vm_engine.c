#include <jni.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <stdlib.h>

#include "cutils.h"
#include "iomem.h"
#include "virtio.h"
#include "machine.h"

/* All callbacks stay on the calling isolated-process thread. No host file or
 * network device is supplied to TinyEMU. Every disk is an explicit mapping. */
typedef struct {
    uint8_t *bytes;
    size_t size;
    int read_only;
} LinuxDisk;

typedef struct {
    JNIEnv *env;
    jobject console;
    jmethodID write;
    jmethodID read;
    jobject cancelled;
    jmethodID get_cancelled;
    int failed;
} LinuxVm;

void vm_error(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
}

static uint64_t monotonic_ms(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) abort();
    return (uint64_t)time.tv_sec * 1000 + time.tv_nsec / 1000000;
}

static int64_t disk_sectors(BlockDevice *device) {
    LinuxDisk *disk = device->opaque;
    return (int64_t)(disk->size / 512);
}

static int disk_range(LinuxDisk *disk, uint64_t sector, int count) {
    return count >= 0 && sector <= disk->size / 512
        && (uint64_t)count <= disk->size / 512 - sector;
}

static int disk_read(BlockDevice *device, uint64_t sector, uint8_t *bytes, int count,
                     BlockDeviceCompletionFunc *completion, void *opaque) {
    (void)completion; (void)opaque;
    LinuxDisk *disk = device->opaque;
    if (!disk_range(disk, sector, count)) return -1;
    memcpy(bytes, disk->bytes + sector * 512, (size_t)count * 512);
    return 0; /* synchronous, no callback retained */
}

static int disk_write(BlockDevice *device, uint64_t sector, const uint8_t *bytes, int count,
                      BlockDeviceCompletionFunc *completion, void *opaque) {
    (void)completion; (void)opaque;
    LinuxDisk *disk = device->opaque;
    if (disk->read_only || !disk_range(disk, sector, count)) return -1;
    memcpy(disk->bytes + sector * 512, bytes, (size_t)count * 512);
    return 0;
}

static void console_write(void *opaque, const uint8_t *bytes, int length) {
    LinuxVm *vm = opaque;
    JNIEnv *env = vm->env;
    if (vm->failed || length < 0 || length > 65536) { vm->failed = 1; return; }
    jbyteArray array = (*env)->NewByteArray(env, length);
    if (!array) { vm->failed = 1; return; }
    (*env)->SetByteArrayRegion(env, array, 0, length, (const jbyte *)bytes);
    if (!(*env)->ExceptionCheck(env)) (*env)->CallVoidMethod(env, vm->console, vm->write, array);
    (*env)->DeleteLocalRef(env, array);
    if ((*env)->ExceptionCheck(env)) vm->failed = 1;
}

static int console_read(void *opaque, uint8_t *bytes, int capacity) {
    LinuxVm *vm = opaque;
    JNIEnv *env = vm->env;
    if (vm->failed || capacity < 1) return 0;
    /* Bound each TTY delivery so the guest can drain canonical input. */
    if (capacity > 32) capacity = 32;
    jbyteArray array = (*env)->NewByteArray(env, capacity);
    if (!array) { vm->failed = 1; return 0; }
    jint count = (*env)->CallIntMethod(env, vm->console, vm->read, array, capacity);
    if ((*env)->ExceptionCheck(env) || count < 0 || count > capacity) {
        vm->failed = 1; count = 0;
    } else if (count) (*env)->GetByteArrayRegion(env, array, 0, count, (jbyte *)bytes);
    (*env)->DeleteLocalRef(env, array);
    return count;
}

JNIEXPORT jint JNICALL
Java_com_minnnng_dsh_1android_LinuxVmEngine_run(JNIEnv *env, jobject owner,
    jobject bios, jobject kernel, jobjectArray disks, jobject console, jobject cancelled, jlong timeout) {
    (void)owner;
    LinuxVm vm = { .env = env, .console = console, .cancelled = cancelled };
    jlong bios_size = (*env)->GetDirectBufferCapacity(env, bios);
    jlong kernel_size = (*env)->GetDirectBufferCapacity(env, kernel);
    uint8_t *bios_bytes = (*env)->GetDirectBufferAddress(env, bios);
    uint8_t *kernel_bytes = (*env)->GetDirectBufferAddress(env, kernel);
    if (!bios_bytes || !kernel_bytes || bios_size < 1 || bios_size > 2 * 1024 * 1024
        || kernel_size < 1 || kernel_size > 32 * 1024 * 1024
        || !disks || timeout < 1000 || timeout > 120000) return -1;
    jsize disk_count = (*env)->GetArrayLength(env, disks);
    if (disk_count < 1 || disk_count > MAX_DRIVE_DEVICE) return -1;
    LinuxDisk mappings[MAX_DRIVE_DEVICE] = {0};
    BlockDevice blocks[MAX_DRIVE_DEVICE] = {0};
    jclass buffer_class = (*env)->FindClass(env, "java/nio/ByteBuffer");
    if (!buffer_class) return -1;
    jmethodID is_read_only = (*env)->GetMethodID(env, buffer_class, "isReadOnly", "()Z");
    (*env)->DeleteLocalRef(env, buffer_class);
    if (!is_read_only) return -1;
    for (jsize i = 0; i < disk_count; i++) {
        jobject buffer = (*env)->GetObjectArrayElement(env, disks, i);
        if (!buffer) return -1;
        jlong size = (*env)->GetDirectBufferCapacity(env, buffer);
        mappings[i].bytes = (*env)->GetDirectBufferAddress(env, buffer);
        mappings[i].read_only = (*env)->CallBooleanMethod(env, buffer, is_read_only);
        (*env)->DeleteLocalRef(env, buffer);
        if ((*env)->ExceptionCheck(env) || !mappings[i].bytes || size < 512
            || size > 256 * 1024 * 1024 || size % 512) return -1;
        mappings[i].size = (size_t)size;
        blocks[i] = (BlockDevice){ .opaque = &mappings[i], .get_sector_count = disk_sectors,
            .read_async = disk_read, .write_async = disk_write };
    }
    jclass console_class = (*env)->GetObjectClass(env, console);
    jclass cancelled_class = (*env)->GetObjectClass(env, cancelled);
    vm.write = (*env)->GetMethodID(env, console_class, "write", "([B)V");
    vm.read = (*env)->GetMethodID(env, console_class, "read", "([BI)I");
    vm.get_cancelled = (*env)->GetMethodID(env, cancelled_class, "get", "()Z");
    (*env)->DeleteLocalRef(env, console_class);
    (*env)->DeleteLocalRef(env, cancelled_class);
    if (!vm.write || !vm.read || !vm.get_cancelled || (*env)->ExceptionCheck(env)) return -1;
    CharacterDevice terminal = { .opaque = &vm, .write_data = console_write, .read_data = console_read };
    VirtMachineParams params = { 0 };
    params.vmc = &riscv_machine_class;
    params.machine_name = "riscv64";
    params.ram_size = 128 * 1024 * 1024;
    params.rtc_real_time = TRUE;
    params.console = &terminal;
    params.drive_count = disk_count;
    for (jsize i = 0; i < disk_count; i++) params.tab_drive[i].block_dev = &blocks[i];
    params.files[VM_FILE_BIOS].buf = bios_bytes;
    params.files[VM_FILE_BIOS].len = (int)bios_size;
    params.files[VM_FILE_KERNEL].buf = kernel_bytes;
    params.files[VM_FILE_KERNEL].len = (int)kernel_size;
    params.cmdline = "loglevel=3 console=hvc0 root=/dev/vda rw init=/bin/sh";
    uint64_t deadline = monotonic_ms() + (uint64_t)timeout;
    VirtMachine *machine = params.vmc->virt_machine_init(&params);
    if (!machine) return -1;
    int result = -1;
    for (;;) {
        if (vm.failed || (*env)->ExceptionCheck(env)) break;
        if ((*env)->CallBooleanMethod(env, cancelled, vm.get_cancelled)) { result = 2; break; }
        if (monotonic_ms() >= deadline) { result = 1; break; }
        if (machine->power_off) { result = 0; break; }
        if (machine->console_dev && virtio_console_can_write_data(machine->console_dev)) {
            uint8_t bytes[32];
            int capacity = virtio_console_get_write_len(machine->console_dev);
            int count = console_read(&vm, bytes, capacity);
            if (count) virtio_console_write_data(machine->console_dev, bytes, count);
        }
        int delay = params.vmc->virt_machine_get_sleep_duration(machine, 2);
        if (delay > 0) {
            struct timespec pause = { .tv_sec = 0, .tv_nsec = (long)delay * 1000000 };
            nanosleep(&pause, NULL);
        }
        params.vmc->virt_machine_interp(machine, 50000);
    }
    params.vmc->virt_machine_end(machine);
    return result;
}
