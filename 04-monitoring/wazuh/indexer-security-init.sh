#!/bin/bash
docker exec -it wazuh-indexer \
/usr/share/wazuh-indexer/opensearch-security/tools/securityadmin.sh \
-cd /usr/share/wazuh-indexer/opensearch-security/ \
-nhnv -cacert /usr/share/wazuh-indexer/certs/root-ca.pem \
-cert /usr/share/wazuh-indexer/certs/admin.pem \
-key /usr/share/wazuh-indexer/certs/admin-key.pem \
-h wazuh.indexer
