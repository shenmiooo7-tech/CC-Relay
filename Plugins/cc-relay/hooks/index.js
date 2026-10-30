import { register as registerCompactor } from './low-quota-compactor.js'
import { register as registerNativeContinuity } from './native-continuity.js'

export function register(on, options) {
  registerCompactor(on, options)
  registerNativeContinuity(on, options)
}
