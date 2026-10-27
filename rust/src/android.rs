//! Android: hands the Java VM and the app's context to `ndk-context`, which cpal's AAudio
//! output asks Android's AudioManager through. MainActivity calls this once at startup.

use std::ffi::c_void;
use std::sync::Once;

/// A raw `JNIEnv*`: a pointer to the JNI function table.
type Env = *mut *const *const c_void;

/// Slots in the JNI function table, fixed by the JNI specification.
const NEW_GLOBAL_REF: usize = 21;
const GET_JAVA_VM: usize = 219;

static INIT: Once = Once::new();

/// `MainActivity.initNative(context)`.
#[no_mangle]
pub extern "system" fn Java_io_github_varixxl_halcyn_MainActivity_initNative(
    env: Env,
    _this: *mut c_void,
    context: *mut c_void,
) {
    INIT.call_once(|| unsafe {
        type NewGlobalRef = unsafe extern "system" fn(Env, *mut c_void) -> *mut c_void;
        type GetJavaVm = unsafe extern "system" fn(Env, *mut *mut c_void) -> i32;
        let table = *env;
        let new_global_ref: NewGlobalRef = std::mem::transmute(*table.add(NEW_GLOBAL_REF));
        let get_java_vm: GetJavaVm = std::mem::transmute(*table.add(GET_JAVA_VM));
        let mut vm = std::ptr::null_mut();
        if get_java_vm(env, &mut vm) != 0 || vm.is_null() {
            return;
        }
        // A global reference: the context has to outlive this call.
        ndk_context::initialize_android_context(vm, new_global_ref(env, context));
    });
}
