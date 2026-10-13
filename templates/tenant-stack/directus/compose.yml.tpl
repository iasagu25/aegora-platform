name: ${TENANT_ID}-directus

services:
  directus:
    image: directus/directus:${DIRECTUS_VERSION}

    container_name: ${DIRECTUS_CONTAINER}

    restart: unless-stopped

    init: true

    env_file:
      - .env

    volumes:
      - ${DIRECTUS_DATA_DIR}/uploads:/directus/uploads
      - ${DIRECTUS_DATA_DIR}/extensions:/directus/extensions

    networks:
      - tenant_backend
      - aegora_proxy

    healthcheck:
      test:
        [
          "CMD-SHELL",
          "wget --spider -q http://127.0.0.1:8055/server/info || exit 1"
        ]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 60s

    security_opt:
      - no-new-privileges:true

    stop_grace_period: 30s

    # Límites de recursos (13/oct/2026). La VPS no tiene swap: sin límites, un tenant
    # que se dispara hace que el OOM killer del sistema mate un contenedor -- y lo elige
    # él, puede ser el de OTRO cliente. Con límite, el que se pasa se reinicia solo
    # (restart: unless-stopped) y los demás ni se enteran.
    # memswap_limit igual que mem_limit: sin swap de verdad, que no cuente con ella.
    # Directus: 230-265 MiB medidos bajo carga. 768 MiB y no 512 porque apply-schema y
    # snapshot-schema ejecutan el CLI DENTRO de este contenedor, y cuentan en el mismo
    # límite que el servidor en marcha.
    mem_limit: 768m
    memswap_limit: 768m
    cpus: 1.0

networks:
  tenant_backend:
    external: true
    name: ${TENANT_BACKEND_NETWORK}

  aegora_proxy:
    external: true
    name: aegora_proxy
