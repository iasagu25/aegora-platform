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

networks:
  tenant_backend:
    external: true
    name: ${TENANT_BACKEND_NETWORK}

  aegora_proxy:
    external: true
    name: aegora_proxy
