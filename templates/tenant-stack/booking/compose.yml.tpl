name: ${TENANT_ID}-booking

services:
  booking:
    image: ${BOOKING_IMAGE}

    container_name: ${BOOKING_CONTAINER}

    restart: unless-stopped

    init: true

    env_file:
      - .env

    networks:
      - tenant_backend
      - aegora_proxy

    healthcheck:
      test:
        [
          "CMD-SHELL",
          "wget --spider -q http://127.0.0.1:3000/api/health || exit 1"
        ]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 30s

    security_opt:
      - no-new-privileges:true

    stop_grace_period: 20s

    # Límites de recursos (13/oct/2026). La VPS no tiene swap: sin límites, un tenant
    # que se dispara hace que el OOM killer del sistema mate un contenedor -- y lo elige
    # él, puede ser el de OTRO cliente. Con límite, el que se pasa se reinicia solo
    # (restart: unless-stopped) y los demás ni se enteran.
    # memswap_limit igual que mem_limit: sin swap de verdad, que no cuente con ella.
    # Booking API (Next.js): no se movió en las pruebas de carga. 384 MiB le sobran.
    mem_limit: 384m
    memswap_limit: 384m
    cpus: 1.0

networks:
  tenant_backend:
    external: true
    name: ${TENANT_BACKEND_NETWORK}

  aegora_proxy:
    external: true
    name: aegora_proxy
