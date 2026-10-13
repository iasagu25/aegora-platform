name: ${TENANT_ID}-n8n

services:
  n8n:
    image: n8nio/n8n:${N8N_VERSION}

    container_name: ${N8N_CONTAINER}

    restart: unless-stopped

    init: true

    env_file:
      - .env

    volumes:
      - ${N8N_DATA_DIR}/storage:/home/node/.n8n
      - ${N8N_DATA_DIR}/files:/files

    networks:
      - tenant_backend
      - aegora_proxy

    healthcheck:
      test:
        [
          "CMD-SHELL",
          "wget --spider -q http://127.0.0.1:5678/healthz || exit 1"
        ]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 90s

    security_opt:
      - no-new-privileges:true

    stop_grace_period: 60s

    # Límites de recursos (13/oct/2026). La VPS no tiene swap: sin límites, un tenant
    # que se dispara hace que el OOM killer del sistema mate un contenedor -- y lo elige
    # él, puede ser el de OTRO cliente. Con límite, el que se pasa se reinicia solo
    # (restart: unless-stopped) y los demás ni se enteran.
    # memswap_limit igual que mem_limit: sin swap de verdad, que no cuente con ella.
    # n8n: ~430 MiB en reposo + ~12 MiB por conversación simultánea (medido el
    # 18/sep/2026 con 40 conversaciones a la vez: pico de 942 MiB). 1,5 GiB deja margen
    # por encima de eso. CPU: es el que más trabaja (agente, tools, transcripción).
    mem_limit: 1536m
    memswap_limit: 1536m
    cpus: 2.0

networks:
  tenant_backend:
    external: true
    name: ${TENANT_BACKEND_NETWORK}

  aegora_proxy:
    external: true
    name: aegora_proxy
