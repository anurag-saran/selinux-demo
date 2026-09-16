### Policy access delta (sesearch)

> Static workshop sample (1.1.0 baseline → 1.1.2 candidate). Live runs use `policy_module_diff.sh` in the compile container.

**Rules ADDED** (app domains, excerpt):

```text
allow myapp_t myapp_log_t:file { append create open write };
allow myapp_t myapp_port_t:tcp_socket name_bind;
allow myapp_t myapp_backend_port_t:tcp_socket name_connect;
allow init_t myapp_exec_t:file { entrypoint execute execute_no_trans ... };
```

**Rules REMOVED:** _(none in this sample)_
