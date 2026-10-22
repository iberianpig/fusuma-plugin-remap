# frozen_string_literal: true

module SHIM
  ffi_func :shim_setup, [], :void
  ffi_func :shim_open_device, [:str], :int
  ffi_func :shim_close, [:int], :int
  ffi_func :shim_grab, [:int], :int
  ffi_func :shim_ungrab, [:int], :int
  ffi_func :shim_device_name, [:int], :str
  ffi_func :shim_device_id, [:int, :ptr], :int
  ffi_func :shim_all_keys_released, [:int], :int
  ffi_func :shim_absinfo, [:int, :int, :ptr], :int
  ffi_func :shim_read_event, [:int, :ptr], :int
  ffi_func :shim_open_uinput, [], :int
  ffi_func :shim_ui_set_evbit, [:int, :int], :int
  ffi_func :shim_ui_set_keybit, [:int, :int], :int
  ffi_func :shim_ui_set_relbit, [:int, :int], :int
  ffi_func :shim_ui_set_absbit, [:int, :int], :int
  ffi_func :shim_ui_set_mscbit, [:int, :int], :int
  ffi_func :shim_ui_set_propbit, [:int, :int], :int
  ffi_func :shim_ui_abs_setup, [:int, :int, :int, :int, :int, :int, :int], :int
  ffi_func :shim_ui_dev_setup, [:int, :str, :int, :int, :int, :int], :int
  ffi_func :shim_ui_dev_create, [:int], :int
  ffi_func :shim_ui_dev_destroy, [:int], :int
  ffi_func :shim_emit, [:int, :int, :int, :int], :int
  ffi_func :shim_wait_any, [:int_array, :size_t, :int], :int
  ffi_func :shim_stdin_fill, [], :int
  ffi_func :shim_stdin_pending, [], :int
  ffi_func :shim_stdin_readline, [], :str
  ffi_func :shim_flush, [], :void

  ffi_buffer :ev_buf, 12
  ffi_read_i32 :ev_type, 0
  ffi_read_i32 :ev_code, 4
  ffi_read_i32 :ev_value, 8

  ffi_buffer :id_buf, 16
  ffi_buffer :abs_buf, 24
end
