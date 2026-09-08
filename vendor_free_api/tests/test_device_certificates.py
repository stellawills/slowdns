import base64
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from device_certificates import CertificateStore
from device_credentials import ProvisioningError


class CertificatesTest(unittest.TestCase):
    def test_real_issuance_replay_and_key_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            ca, key = root/'ca.pem', root/'ca.key'
            subprocess.run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256',
                            '-nodes','-keyout',str(key),'-out',str(ca),'-days','3','-subj','/CN=Test CA',
                            '-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign'],
                           check=True, capture_output=True)
            ca.chmod(0o600); key.chmod(0o600)
            public = subprocess.run(['openssl','pkey','-in',str(key),'-pubout','-outform','DER'],
                                    check=True,capture_output=True).stdout
            config = {'openvpn':{'enabled':True}, 'provisioning':{'enabled':True,'server_id':'test',
                      'db_path':str(root/'db.sqlite'),'openvpn_device_certificates':True,
                      'client_ca_key':str(key),'client_ca_certificate':str(ca),
                      'openvpn_management':{'udp':'/run/iptunnel-provisioning/udp.sock'}}}
            store = CertificateStore(config)
            store.store.heartbeat('udp', True)
            body = dict(owner_id='a'*64,protocol='openvpn',request_id='b'*32,recover=False,
                        tls_public_key=base64.b64encode(public).decode())
            result = store.provision(body)
            self.assertEqual(result, store.provision(body))
            leaf = root/'leaf.pem'; leaf.write_text(result['certificate_pem'])
            subprocess.run(['openssl','verify','-purpose','sslclient','-CAfile',str(ca),str(leaf)],
                           check=True,capture_output=True)
            self.assertFalse(store.store.authorize('udp','1',result['username'],result['password']))
            self.assertFalse(store.store.authorize('udp','1',result['username'],result['password'],'wrong'))
            self.assertTrue(store.store.authorize('udp','1',result['username'],result['password'],result['username']))
            with self.assertRaises(ProvisioningError):
                store.provision(dict(body,tls_public_key='invalid'))

if __name__ == '__main__':
    unittest.main()
