#!/usr/bin/env bash
# Zabbix 8.0 RC1 + PostgreSQL 18 + TimescaleDB 2.29.x no Ubuntu 24.04/26.04, variáveis ZBX_* no README

set -euo pipefail

DB_NAME="zabbix"
DB_USER="zabbix"
PG_VER="${ZBX_PG_VER:-18}"
TSDB_SERIES="${ZBX_TSDB_SERIES:-2.29}"
SQL_DIR="/usr/share/zabbix/sql-scripts/postgresql"
LOG_FILE="/var/log/zabbix-install.log"

log() { echo -e "\n\033[1;36m>>> $*\033[0m"; }
die() { echo -e "\033[1;31mERRO: $*\033[0m" >&2; exit 1; }

# Valida root e sistema operacional
[[ $EUID -eq 0 ]] || die "execute como root (sudo)"
source /etc/os-release
[[ "${ID}" == "ubuntu" && ( "${VERSION_ID}" == "24.04" || "${VERSION_ID}" == "26.04" ) ]] || die "requer Ubuntu 24.04 ou 26.04 (encontrado: ${PRETTY_NAME})"
CODENAME="$(lsb_release -c -s 2>/dev/null || echo "${VERSION_CODENAME}")"

# fd 3 = terminal original, senha fora do log
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
exec 3>&1
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo -e "\033[1;31mERRO na linha ${LINENO}: ${BASH_COMMAND}\033[0m" >&2' ERR
export DEBIAN_FRONTEND=noninteractive

# Senha do banco: variável de ambiente ou gerada aleatoriamente
DB_PASS="${ZBX_DB_PASS:-$(openssl rand -hex 16)}"
[[ "$DB_PASS" =~ ^[A-Za-z0-9._@%+=-]+$ ]] || die "ZBX_DB_PASS só pode conter letras, números e . _ @ % + = -"

log "Verificando repositórios de terceiros para ${CODENAME}"
curl -fsI "https://packagecloud.io/timescale/timescaledb/ubuntu/dists/${CODENAME}/Release" >/dev/null 2>&1 \
  || die "repositório TimescaleDB sem suporte para ${CODENAME}, use Ubuntu 24.04 ou aguarde o suporte"
curl -fsI "https://apt.postgresql.org/pub/repos/apt/dists/${CODENAME}-pgdg/Release" >/dev/null 2>&1 \
  || die "repositório PGDG sem suporte para ${CODENAME}, use Ubuntu 24.04 ou aguarde o suporte"

log "Instalando pacotes base"
apt-get update
apt-get install -y gnupg postgresql-common apt-transport-https lsb-release wget curl ca-certificates

log "Configurando repositório PostgreSQL (PGDG)"
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

log "Configurando repositório TimescaleDB"
mkdir -p /etc/apt/keyrings
curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | gpg --dearmor --yes -o /etc/apt/keyrings/timescaledb.gpg
echo "deb [signed-by=/etc/apt/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -c -s) main" \
  > /etc/apt/sources.list.d/timescaledb.list
apt-get update

log "Selecionando PostgreSQL ${PG_VER} e TimescaleDB ${TSDB_SERIES}.x"
apt-cache show "postgresql-${PG_VER}" >/dev/null 2>&1 || die "postgresql-${PG_VER} indisponível nos repositórios"
# Maior versão da série TimescaleDB solicitada disponível para este PostgreSQL
TSDB_PKG_VER="$(apt-cache madison "timescaledb-2-postgresql-${PG_VER}" | awk '{print $3}' | grep -E "^(1:)?${TSDB_SERIES//./\\.}\\." | sort -rV | head -1 || true)"
[[ -n "$TSDB_PKG_VER" ]] || die "timescaledb-2-postgresql-${PG_VER} série ${TSDB_SERIES}.x indisponível (versões: $(apt-cache madison "timescaledb-2-postgresql-${PG_VER}" | awk '{print $3}' | tr '\n' ' '))"
echo "TimescaleDB escolhido: ${TSDB_PKG_VER}"

log "Instalando PostgreSQL ${PG_VER} e TimescaleDB ${TSDB_PKG_VER}"
apt-get install -y "postgresql-${PG_VER}" \
  "timescaledb-2-postgresql-${PG_VER}=${TSDB_PKG_VER}" "timescaledb-2-loader-postgresql-${PG_VER}=${TSDB_PKG_VER}" timescaledb-tools
# Impede que o apt suba o TimescaleDB para fora da série escolhida
apt-mark hold "timescaledb-2-postgresql-${PG_VER}" "timescaledb-2-loader-postgresql-${PG_VER}"

log "Aplicando timescaledb-tune"
timescaledb-tune --quiet --yes
systemctl restart postgresql

TSDB_VER="$(dpkg-query -W -f='${Version}' "timescaledb-2-postgresql-${PG_VER}" 2>/dev/null || true)"
[[ -n "$TSDB_VER" ]] || die "não foi possível obter a versão instalada do TimescaleDB"
echo "TimescaleDB instalado: ${TSDB_VER} (mínimo exigido: 2.20.0)"
dpkg --compare-versions "${TSDB_VER%%~*}" ge 2.20.0 || die "TimescaleDB abaixo de 2.20.0"

log "Localizando pacote do repositório Zabbix 8.0"
BASE="https://repo.zabbix.com/zabbix/8.0"
DEB="zabbix-release_latest+ubuntu${VERSION_ID}_all.deb"
RELEASE_URL="${ZBX_RELEASE_URL:-}"
if [[ -z "$RELEASE_URL" ]]; then
  # Tenta unstable (RC) e depois release (GA)
  for channel in unstable release; do
    candidate="${BASE}/${channel}/ubuntu/pool/main/z/zabbix-release/${DEB}"
    if curl -fsI "$candidate" >/dev/null 2>&1; then RELEASE_URL="$candidate"; break; fi
  done
fi
[[ -n "$RELEASE_URL" ]] || die "pacote não encontrado, defina ZBX_RELEASE_URL com o .deb de ${BASE}/unstable/ubuntu/"
echo "Usando: ${RELEASE_URL}"

log "Instalando repositório Zabbix"
cd /tmp
rm -f zabbix-release_*.deb
wget -q "$RELEASE_URL" -O zabbix-release.deb
dpkg -i zabbix-release.deb
apt-get update

log "Instalando Zabbix server, frontend e agent 2"
# php-fpm antes do zabbix-apache-conf, para o apt não resolver a dependência com libapache2-mod-php
apt-get install -y php-fpm
apt-get install -y php-curl php-pgsql zabbix-server-pgsql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent2

PHP_VER="$(php -r 'echo PHP_VERSION;')"
dpkg --compare-versions "$PHP_VER" ge 8.2.0 || die "PHP ${PHP_VER} abaixo do mínimo 8.2.0"

log "Criando usuário e banco"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  echo "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';" | sudo -u postgres psql -q
else
  die "usuário ${DB_USER} já existe, este script é para instalação nova"
fi
sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"

log "Importando esquema inicial"
[[ -d "$SQL_DIR" ]] || SQL_DIR="/usr/share/zabbix-sql-scripts/postgresql"
[[ -f "${SQL_DIR}/server.sql.gz" ]] || die "server.sql.gz não encontrado em ${SQL_DIR}"
zcat "${SQL_DIR}/server.sql.gz" | sudo -u "${DB_USER}" psql -q "${DB_NAME}"

log "Habilitando TimescaleDB e criando hypertables"
sudo -u postgres psql -d "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;"
cat "${SQL_DIR}/timescaledb/schema.sql" | sudo -u "${DB_USER}" psql -q "${DB_NAME}"

log "Configurando zabbix_server.conf"
CONF="/etc/zabbix/zabbix_server.conf"
sed -i -E '/^#?\s*(DBHost|DBName|DBUser|DBPassword)=/d' "$CONF"
{
  echo "DBHost=localhost"
  echo "DBName=${DB_NAME}"
  echo "DBUser=${DB_USER}"
  echo "DBPassword=${DB_PASS}"
} >> "$CONF"

log "Ajustando limites de conexão do PostgreSQL"
PGCONF="/etc/postgresql/${PG_VER}/main/postgresql.conf"
sed -i -E 's/^#?\s*max_connections\s*=.*/max_connections = 100/' "$PGCONF"
sed -i -E 's/^#?\s*superuser_reserved_connections\s*=.*/superuser_reserved_connections = 5/' "$PGCONF"
systemctl restart postgresql

log "Instalando locale pt_BR"
apt-get install -y language-pack-pt-base language-pack-pt
locale-gen pt_BR pt_BR.UTF-8

log "Preparando Apache e PHP-FPM para o frontend"
# PHP somente via PHP-FPM + mpm_event, sem mod_php
SWITCH_MPM=0
shopt -s nullglob
for f in /etc/apache2/mods-enabled/php*.load; do
  m="$(basename "$f" .load)"
  echo "Desabilitando mod_php: ${m}"
  a2dismod "$m" >/dev/null
  SWITCH_MPM=1
done
shopt -u nullglob
if [[ "$SWITCH_MPM" == 1 ]]; then
  a2dismod mpm_prefork >/dev/null 2>&1 || true
  a2enmod mpm_event >/dev/null
fi
a2enmod proxy proxy_fcgi setenvif >/dev/null

PHP_FPM_SVC="$(systemctl list-unit-files --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}' | head -1 || true)"
[[ -n "$PHP_FPM_SVC" ]] || die "serviço php-fpm não encontrado"
PHPV="${PHP_FPM_SVC#php}"; PHPV="${PHPV%-fpm.service}"

# Handler que manda os .php para o PHP-FPM (fornecido pelo pacote php-fpm)
[[ -f "/etc/apache2/conf-available/php${PHPV}-fpm.conf" ]] || die "php${PHPV}-fpm.conf não encontrado em /etc/apache2/conf-available"
a2enconf "php${PHPV}-fpm" >/dev/null

# Limites exigidos pelo Zabbix aplicados no PHP-FPM
TZ_SYS="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
TZ_SYS="${TZ_SYS:-UTC}"
cat > "/etc/php/${PHPV}/fpm/conf.d/99-zabbix.ini" <<ZBXINI
max_execution_time = 300
memory_limit = 128M
post_max_size = 16M
upload_max_filesize = 2M
max_input_time = 300
max_input_vars = 10000
date.timezone = ${TZ_SYS}
ZBXINI

apache2ctl configtest
systemctl enable "$PHP_FPM_SVC"
systemctl restart "$PHP_FPM_SVC"

log "Iniciando serviços"
systemctl restart zabbix-server zabbix-agent2 apache2
systemctl enable zabbix-server zabbix-agent2 apache2
sleep 5

# O PHP precisa ser executado, nao entregue como texto
BODY="$(curl -s http://localhost/zabbix/setup.php | head -c 5 || true)"
[[ "$BODY" != "<?php" ]] || die "Apache está entregando o PHP como texto, handler PHP-FPM não está ativo"

log "Verificação"
systemctl is-active zabbix-server zabbix-agent2 apache2 postgresql "$PHP_FPM_SVC"
grep -iE "starting zabbix server|database upgrade|cannot|error" /var/log/zabbix/zabbix_server.log | tail -5 || true

# Falha se o Zabbix rejeitou a versão do banco (a versão do PostgreSQL pode estar acima do suportado)
if grep -qiE "unsupported .*(postgresql|timescaledb)|database version.*(not supported|unsupported)" /var/log/zabbix/zabbix_server.log; then
  die "Zabbix reportou versão de banco não suportada, o Zabbix 8.0 RC1 pode não suportar PostgreSQL ${PG_VER} ou TimescaleDB ${TSDB_VER}, ajuste ZBX_PG_VER/ZBX_TSDB_SERIES e reinstale em máquina limpa"
fi

sleep 1  # deixa o tee terminar de gravar antes do resumo
IP="$(hostname -I | awk '{print $1}')"
{
  echo
  echo "Instalação concluída."
  echo "Frontend: http://${IP}/zabbix"
  echo "PostgreSQL: ${PG_VER} | TimescaleDB: ${TSDB_VER}"
  echo "Banco: ${DB_NAME} | Usuário: ${DB_USER} | Senha: ${DB_PASS}"
  echo "A senha também está em DBPassword no /etc/zabbix/zabbix_server.conf"
  echo "Log da instalação (sem a senha): ${LOG_FILE}"
} >&3
echo "Instalação concluída (resumo com a senha exibido apenas no terminal)"
