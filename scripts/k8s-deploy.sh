#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# k8s-deploy.sh — Aplica o overlay Kustomize do repo CHAMADOR (repo do serviço,
# checked out no diretório de trabalho atual pelo deploy.yml reutilizável),
# substituindo a imagem placeholder pela recém publicada no ECR.
#
# Réplica adaptada de phase-3/app/scripts/k8s-deploy.sh — mantém o isolamento
# via diretório temporário e o timeout/skip de rollout configuráveis, mas:
#   - opera sobre `./k8s` (diretório de trabalho atual, do repo CHAMADOR) em
#     vez de um path relativo ao próprio script — este script roda a partir
#     de outro repo (`pipelines`, checked out em `.pipelines/`), não do mesmo
#     repo do k8s/ que ele aplica;
#   - sem `envsubst` — nem para credenciais (ExternalSecret do repo `infra` já
#     sincroniza os Secrets que o Deployment referencia via secretKeyRef) nem
#     para a imagem (usa `kustomize edit set image`, mecanismo nativo do
#     Kustomize, em vez de substituição de texto);
#   - valida rollout de 1 Deployment conhecido (K8S_DEPLOYMENT), não descobre
#     recursos genericamente — cada overlay aqui tem exatamente 1 Deployment.
#
# Variáveis obrigatórias (vêm do deploy.yml reutilizável):
#   ENVIRONMENT     — nome do overlay (lab, develop, ...)
#   IMAGE_URI       — imagem recém publicada no ECR (registry/repo:tag)
#   K8S_DEPLOYMENT  — nome do Deployment (para o rollout status)
#   K8S_NAMESPACE   — namespace onde o Deployment é aplicado
#
# Variáveis opcionais:
#   ROLLOUT_TIMEOUT     — default "180s"
#   SKIP_ROLLOUT_CHECK  — default "false"
# ---------------------------------------------------------------------------

REQUIRED_VARS=(ENVIRONMENT IMAGE_URI K8S_DEPLOYMENT K8S_NAMESPACE)
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
SKIP_ROLLOUT_CHECK="${SKIP_ROLLOUT_CHECK:-false}"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

fail() {
  log "❌ $*"
  exit 1
}

cleanup_tmp_dir() {
  if [[ -n "${TMP_BUILD_DIR:-}" && -d "${TMP_BUILD_DIR}" ]]; then
    log "🧹 Limpando diretório temporário: ${TMP_BUILD_DIR}"
    rm -rf "${TMP_BUILD_DIR}"
  fi
}

trap cleanup_tmp_dir EXIT

log "🔑 Verificando variáveis de ambiente obrigatórias..."
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    fail "Variável obrigatória não definida: ${var}"
  fi
done
log "✅ Todas as variáveis obrigatórias estão definidas."

BASE_SRC="k8s/base"
OVERLAY_SRC="k8s/overlays/${ENVIRONMENT}"

[[ -d "${BASE_SRC}" ]] || fail "Base Kustomize não encontrada: ${BASE_SRC}"
[[ -d "${OVERLAY_SRC}" ]] || fail "Overlay não encontrado para o ambiente '${ENVIRONMENT}': ${OVERLAY_SRC}"
[[ -f "${BASE_SRC}/kustomization.yaml" ]] || fail "kustomization.yaml não encontrado na base: ${BASE_SRC}"
[[ -f "${OVERLAY_SRC}/kustomization.yaml" ]] || fail "kustomization.yaml não encontrado no overlay: ${OVERLAY_SRC}"

log "🔎 Validando acesso ao cluster..."
kubectl cluster-info >/dev/null
kubectl auth can-i get pods -n "${K8S_NAMESPACE}" >/dev/null || fail "Sem permissão mínima no cluster (get pods em ${K8S_NAMESPACE})."

TMP_BUILD_DIR="$(mktemp -d)"
TMP_K8S_DIR="${TMP_BUILD_DIR}/k8s"
TMP_BASE_DIR="${TMP_K8S_DIR}/base"
TMP_OVERLAY_DIR="${TMP_K8S_DIR}/overlays/${ENVIRONMENT}"
BUILT_MANIFESTS_FILE="${TMP_BUILD_DIR}/built-manifests.yaml"

log "📦 Copiando base e overlay para diretório temporário (preserva o checkout original)..."
mkdir -p "${TMP_K8S_DIR}/overlays"
cp -r "${BASE_SRC}" "${TMP_BASE_DIR}"
cp -r "${OVERLAY_SRC}" "${TMP_OVERLAY_DIR}"

log "🏷️ Definindo imagem: ${IMAGE_URI}"
(cd "${TMP_OVERLAY_DIR}" && kustomize edit set image "placeholder=${IMAGE_URI}")

log "🔧 Construindo manifests finais com Kustomize..."
kustomize build "${TMP_OVERLAY_DIR}" > "${BUILT_MANIFESTS_FILE}"
[[ -s "${BUILT_MANIFESTS_FILE}" ]] || fail "Manifestos gerados estão vazios."

log "🚀 Aplicando manifests no cluster (namespace ${K8S_NAMESPACE})..."
kubectl apply -f "${BUILT_MANIFESTS_FILE}"

if [[ "${SKIP_ROLLOUT_CHECK}" != "true" ]]; then
  log "⏳ Aguardando rollout de ${K8S_DEPLOYMENT} em ${K8S_NAMESPACE} (timeout: ${ROLLOUT_TIMEOUT})..."
  kubectl rollout status "deployment/${K8S_DEPLOYMENT}" -n "${K8S_NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT}"
else
  log "⚠️ SKIP_ROLLOUT_CHECK=true, validação de rollout ignorada."
fi

log "✅ Deploy concluído: ${K8S_DEPLOYMENT} (${ENVIRONMENT})"
