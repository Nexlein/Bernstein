// Checks our baseline rules (CLAUDE.md, ADR 0030) on the rendered manifests. No dependency.
// Input: the objects of `kubectl kustomize k8s/` as one JSON array on stdin.
// Usage: kubectl kustomize k8s/ | yq ea -o=json '[.]' | node scripts/check-baseline.mjs
// Prints one FAIL line per broken rule, naming the object; exits 1 if there is any.

import { readFileSync } from 'node:fs';

const PUBLIC = ['poll', 'result']; // Public apps: 2+ pods, probes, preStop, PDB, LoadBalancer.
const objects = JSON.parse(readFileSync(0, 'utf8')).filter(Boolean);
const failures = [];
const fail = (obj, rule, message) =>
  failures.push(`FAIL ${obj.kind}/${obj.metadata.name}: ${message} (rule ${rule})`);
const named = (kind, name) => objects.find((o) => o.kind === kind && o.metadata.name === name);
const workloads = objects.filter((o) => o.kind === 'Deployment' || o.kind === 'StatefulSet');

for (const obj of workloads) {
  const pod = obj.spec.template.spec;
  const containers = [...(pod.initContainers ?? []), ...pod.containers];

  // 1. Requests and limits, CPU and memory, on every container.
  for (const c of containers) {
    for (const kind of ['requests', 'limits']) {
      for (const resource of ['cpu', 'memory']) {
        if (!c.resources?.[kind]?.[resource])
          fail(obj, 1, `container ${c.name} has no resources.${kind}.${resource}`);
      }
    }
  }

  // 2. Non-root, no privilege escalation: runAsNonRoot on the pod or on every container.
  for (const c of containers) {
    if ((c.securityContext?.runAsNonRoot ?? pod.securityContext?.runAsNonRoot) !== true) {
      fail(obj, 2, `container ${c.name} does not set runAsNonRoot: true`);
    }
    if (c.securityContext?.allowPrivilegeEscalation !== false) {
      fail(obj, 2, `container ${c.name} does not set allowPrivilegeEscalation: false`);
    }
  }

  // 3. Zero-downtime rollout on every Deployment.
  if (obj.kind === 'Deployment') {
    const rolling = obj.spec.strategy?.rollingUpdate;
    if (obj.spec.strategy?.type !== 'RollingUpdate')
      fail(obj, 3, 'strategy.type is not RollingUpdate');
    if (rolling?.maxSurge !== 1) fail(obj, 3, `maxSurge is ${rolling?.maxSurge}, not 1`);
    if (rolling?.maxUnavailable !== 0)
      fail(obj, 3, `maxUnavailable is ${rolling?.maxUnavailable}, not 0`);
    if (obj.spec.minReadySeconds !== 5)
      fail(obj, 3, `minReadySeconds is ${obj.spec.minReadySeconds}, not 5`);
  }
}

for (const app of PUBLIC) {
  const deploy = named('Deployment', app);
  if (!deploy) {
    failures.push(`FAIL Deployment/${app}: missing (rule 4)`);
    continue;
  }

  // 4. At least 2 pods: from the HPA when one targets the Deployment (then no replicas, or every
  // apply would reset the HPA's count), else from replicas.
  const hpa = objects.find(
    (o) => o.kind === 'HorizontalPodAutoscaler' && o.spec.scaleTargetRef?.name === app,
  );
  if (hpa) {
    if (!(hpa.spec.minReplicas >= 2))
      fail(hpa, 4, `minReplicas is ${hpa.spec.minReplicas}, below 2`);
    if (deploy.spec.replicas !== undefined)
      fail(deploy, 4, 'sets replicas although an HPA scales it');
  } else if (!(deploy.spec.replicas >= 2)) {
    fail(deploy, 4, `replicas is ${deploy.spec.replicas ?? '1 (default)'}, below 2`);
  }

  // 5. Probes and preStop on the app container, and a PodDisruptionBudget that selects its pods.
  const c =
    deploy.spec.template.spec.containers.find((x) => x.name === app) ??
    deploy.spec.template.spec.containers[0];
  if (!c.readinessProbe) fail(deploy, 5, `container ${c.name} has no readinessProbe`);
  if (!c.livenessProbe) fail(deploy, 5, `container ${c.name} has no livenessProbe`);
  if (!c.lifecycle?.preStop) fail(deploy, 5, `container ${c.name} has no preStop hook`);
  const labels = deploy.spec.template.metadata.labels ?? {};
  const pdb = objects.find(
    (o) =>
      o.kind === 'PodDisruptionBudget' &&
      Object.entries(o.spec.selector?.matchLabels ?? { none: true }).every(
        ([k, v]) => labels[k] === v,
      ),
  );
  if (!pdb) fail(deploy, 5, 'no PodDisruptionBudget selects its pods');
}

// 6. Only Poll and Result are public.
for (const svc of objects.filter((o) => o.kind === 'Service')) {
  const type = svc.spec.type ?? 'ClusterIP';
  const expected = PUBLIC.includes(svc.metadata.name) ? 'LoadBalancer' : 'ClusterIP';
  if (type !== expected) fail(svc, 6, `type is ${type}, not ${expected}`);
}

if (failures.length) {
  console.error(failures.join('\n'));
  console.error(
    `${failures.length} baseline rule(s) broken. The rules: CLAUDE.md, "Our Baseline Rules", and ADR 0030.`,
  );
  process.exit(1);
}
console.log(`Baseline rules OK: ${workloads.length} workloads, ${objects.length} objects.`);
