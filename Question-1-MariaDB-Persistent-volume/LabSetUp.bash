#!/bin/bash
set -e

echo "Creating namespace..."
kubectl create ns mariadb --dry-run=client -o yaml | kubectl apply -f -

echo "Creating StorageClass with Retain policy..."
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: mariadb-retain
provisioner: rancher.io/local-path
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
EOF

echo "Creating initial PVC..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb
  namespace: mariadb
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: mariadb-retain
  resources:
    requests:
      storage: 250Mi
EOF

echo "Creating initial MariaDB Deployment..."
cat <<EOF > ~/mariadb-deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
  namespace: mariadb
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mariadb
  template:
    metadata:
      labels:
        app: mariadb
    spec:
      containers:
      - name: mariadb
        image: mariadb:10.6
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: rootpass
        volumeMounts:
        - name: mariadb-storage
          mountPath: /var/lib/mysql
      volumes:
      - name: mariadb-storage
        persistentVolumeClaim:
          claimName: mariadb
EOF

kubectl apply -f ~/mariadb-deploy.yaml

echo "Waiting for MariaDB pod to start (triggers PV dynamic provisioning)..."
kubectl wait --for=condition=Available deployment/mariadb -n mariadb --timeout=90s || true

echo "Capturing dynamically provisioned PV name..."
PV_NAME=$(kubectl get pvc mariadb -n mariadb -o jsonpath='{.spec.volumeName}')
if [ -z "$PV_NAME" ]; then
  echo "ERROR: PVC not bound yet, PV name could not be resolved."
  exit 1
fi
echo "   - PV name: $PV_NAME"

echo "Simulating accidental deletion of Deployment and PVC..."
kubectl delete deployment mariadb -n mariadb --ignore-not-found
kubectl delete pvc mariadb -n mariadb --ignore-not-found

echo "Waiting for PV to reach Released state..."
kubectl wait --for=jsonpath='{.status.phase}'=Released pv/$PV_NAME --timeout=30s || true

echo "Clearing stale claimRef so PV returns to Available..."
kubectl patch pv $PV_NAME --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'

echo "Writing lab deployment manifest (claimName left blank for user to fill)..."
cat <<'EOF' > ~/mariadb-deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
  namespace: mariadb
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mariadb
  template:
    metadata:
      labels:
        app: mariadb
    spec:
      containers:
      - name: mariadb
        image: mariadb:10.6
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: rootpass
        volumeMounts:
        - name: mariadb-storage
          mountPath: /var/lib/mysql
      volumes:
      - name: mariadb-storage
        persistentVolumeClaim:
          claimName: ""
EOF

echo ""
echo "[OK] Lab setup complete!"
echo "   - Namespace:       mariadb"
echo "   - PV name:         $PV_NAME"
echo "   - PV status:       Available (Retain policy, data intact)"
echo "   - Deployment file: ~/mariadb-deploy.yaml (claimName is blank)"