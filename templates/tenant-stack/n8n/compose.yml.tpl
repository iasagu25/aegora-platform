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

networks:
  tenant_backend:
    external: true
    name: ${TENANT_BACKEND_NETWORK}

  aegora_proxy:
    external: true
    name: aegora_proxy
