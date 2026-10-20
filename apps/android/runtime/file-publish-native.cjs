const path = require('node:path')
const native = { exports: {} }
process.dlopen(native, path.join(process.env.DSH_ANDROID_NATIVE_LIBRARY_DIR, 'libpocket_file_publish.so'))
module.exports = native.exports
