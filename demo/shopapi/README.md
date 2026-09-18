# shopapi — Spring Boot demo reference

This is the **demo** JVM. Flask `app/` remains the **test** reference (`make check` stays offline and fast).

Policy starts as a **types-only** seed in `selinux/shopapi/`. The allow list is generated on rhel-qa from **observed** AVCs (`dev_generate_policy.sh --app-name shopapi`). Do not paste a JVM permission list; if `execmem` does not appear in the AVC log, do not add it.

systemd starts the process with **`SELinuxContext=`** because `/usr/bin/java` is a shared `bin_t`/`java_exec_t` binary and cannot carry this app's entrypoint. The labelled-wrapper alternative is documented in `shopapi.service`.

Paths and port: `config/shopapi.manifest.yml` → `/etc/shopapi.env` (bootstrap writes that file).
