const path = require('node:path')
// Android executes native code from the APK's library directory.
const native = { exports: {} }
process.dlopen(native, path.join(process.env.DSH_ANDROID_NATIVE_LIBRARY_DIR, 'libpocket_require_builtin.so'))
module.exports = native.exports
