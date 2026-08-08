ARG STUDIO_BASE_IMAGE=supabase/studio:2026.07.07-sha-a6a04f2
FROM ${STUDIO_BASE_IMAGE}

LABEL org.opencontainers.image.title="Ultrabase Studio"
LABEL org.opencontainers.image.description="Supabase Studio with the local Ultrabase purple identity"

USER root

COPY apps/studio/styles/ultrabase.css /tmp/ultrabase.css
COPY apps/studio/public/img/supabase-logo.svg /tmp/ultrabase-logo.svg

RUN set -eux; \
    cp /tmp/ultrabase-logo.svg /app/apps/studio/public/img/supabase-logo.svg; \
    cp /tmp/ultrabase-logo.svg /app/apps/studio/public/supabase-logo.svg; \
    cp /tmp/ultrabase-logo.svg /app/apps/studio/public/favicon/ultrabase.svg; \
    cp /tmp/ultrabase-logo.svg /app/apps/studio/public/favicon/staging/ultrabase.svg; \
    find /app/apps/studio/.next/static -type f -name '*.css' \
      -exec sh -c 'cat /tmp/ultrabase.css >> "$1"' _ {} \;; \
    find /app/apps/studio/.next /app/apps/studio/server.js \
      -type f \( -name '*.js' -o -name '*.html' -o -name '*.json' \) \
      -exec sed -i \
        -e 's/Supabase Studio/Ultrabase Studio/g' \
        -e 's/"app:title":null/"app:title":"Ultrabase"/g' \
        -e 's/"Supabase"/"Ultrabase"/g' \
        -e 's/>Supabase</>Ultrabase</g' \
        -e 's/1E1E1E/7C3AED/g' \
        -e 's/favicon\.ico/ultrabase.svg/g' \
        -e 's#image/x-icon#image/svg+xml#g' {} +; \
    sed -i \
      -e 's/Supabase Studio/Ultrabase Studio/g' \
      -e 's/"short_name": "Supabase"/"short_name": "Ultrabase"/g' \
      -e 's/#1C1C1C/#7C3AED/g' \
      /app/apps/studio/public/favicon/manifest.json \
      /app/apps/studio/public/favicon/staging/manifest.json; \
    rm -f /tmp/ultrabase.css /tmp/ultrabase-logo.svg
