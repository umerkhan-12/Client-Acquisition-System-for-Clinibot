# n8n for Railway. Same version as the local container, so workflows built
# and verified locally behave identically here.
#
# Built from a staging directory assembled by deploy.sh, never from the repo
# root: the seed/ directory holds a snapshot of n8n's database (encrypted
# credentials, owner login) and must not be committed.
FROM docker.n8n.io/n8nio/n8n:2.27.3

USER root
# Supabase's pooler presents a certificate signed by Supabase's own root CA.
COPY supabase-root-2021.crt /opt/certs/supabase-root-2021.crt
COPY entrypoint.sh /railway-entrypoint.sh
COPY seed/ /opt/seed/
RUN chmod 0755 /railway-entrypoint.sh && chmod -R go-rwx /opt/seed

ENTRYPOINT ["tini", "--", "/railway-entrypoint.sh"]
