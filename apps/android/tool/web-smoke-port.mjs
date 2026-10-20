import { WebAccess as ProductWebAccess } from '../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/web-access.mjs'

/** Keep the product lifecycle while letting the OS atomically allocate test ports. */
export class WebAccess extends ProductWebAccess {
  validate(value) {
    if (value.port !== 0) return super.validate(value)
    return { ...super.validate({ ...value, port: 3080 }), port: 0 }
  }
}
