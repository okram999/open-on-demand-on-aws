#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

dnf install python3-pip httpd -y -q
systemctl restart httpd

# Install yq
wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq &&\
chmod +x /usr/bin/yq

wget -O /tmp/ondemand-release-web-4.0-1.amzn2023.noarch.rpm https://yum.osc.edu/ondemand/4.0/ondemand-release-web-4.0-1.amzn2023.noarch.rpm
dnf install /tmp/ondemand-release-web-4.0-1.amzn2023.noarch.rpm -yq
dnf update -yq
dnf install ondemand ondemand-dex krb5-workstation samba -yq

# Fix for node-pty module compatibility issues
dnf install gcc-c++ make nodejs-devel -y -q
cd /var/www/ood/apps/sys/shell
npm rebuild node-pty
cd -

echo "$(date +%Y%m%d-%H%M) | ood installed" >> /var/log/install.txt
export AD_SECRET=$(aws secretsmanager --region $AWS_REGION get-secret-value --secret-id $AD_SECRET_ID --query SecretString --output text)
export AD_PASSWORD=$(aws secretsmanager --region $AWS_REGION get-secret-value --secret-id $AD_PASSWORD --query SecretString --output text)

cat << EOF >> /etc/sssd/sssd.conf
[domain/$DOMAIN_NAME.$TOP_LEVEL_DOMAIN]
cache_credentials = True
debug_level = 0x1ff
default_shell = /bin/bash
fallback_homedir = /shared/home/%u
id_provider = ldap
ldap_auth_disable_tls_never_use_in_production = true
ldap_default_authtok = $AD_PASSWORD
ldap_default_bind_dn = CN=Admin,OU=Users,OU=$DOMAIN_NAME,DC=$DOMAIN_NAME,DC=$TOP_LEVEL_DOMAIN
ldap_id_mapping = True
ldap_referrals = False
ldap_schema = AD
ldap_search_base = DC=$DOMAIN_NAME,DC=$TOP_LEVEL_DOMAIN
ldap_tls_reqcert = never
ldap_uri = ldap://$LDAP_NLB
use_fully_qualified_names = False

[sssd]
config_file_version = 2
services = nss, pam
domains = $DOMAIN_NAME.$TOP_LEVEL_DOMAIN
full_name_format = %1\$s

[nss]
filter_users = nobody,root
filter_groups = nobody,root

[pam]
offline_credentials_expiration = 7
EOF

chown root:root /etc/sssd/sssd.conf
chmod 600 /etc/sssd/sssd.conf
systemctl restart sssd

if [ "$OOD_HTTP" = "true" ]; then
  # Convert WEBSITE_DOMAIN to lowercase
  WEBSITE_DOMAIN=$(echo "$WEBSITE_DOMAIN" | tr '[:upper:]' '[:lower:]')

  sed -i "s/#port: null/port: 80/" /etc/ood/config/ood_portal.yml
fi
sed -i "s/#servername: null/servername: $WEBSITE_DOMAIN/" /etc/ood/config/ood_portal.yml

if [[ "$OOD_HTTP" == "false" ]]; then
  cat << EOF >> /etc/ood/config/ood_portal.yml
ssl:
  - 'SSLCertificateFile "/etc/ssl/private/cert.crt"'
  - 'SSLCertificateKeyFile "/etc/ssl/private/private_key.key"'
EOF
fi

cat << EOF >> /etc/ood/config/ood_portal.yml
dex_uri: /dex
dex:
    ssl: true
    connectors:
        - type: ldap
          id: ldap
          name: LDAP
          config:
            host: $LDAP_NLB
            insecureSkipVerify: false
            insecureNoSSL: true
            bindDN: CN=Admin,OU=Users,OU=$DOMAIN_NAME,DC=$DOMAIN_NAME,DC=$TOP_LEVEL_DOMAIN
            bindPW: "$AD_PASSWORD"
            userSearch:
              baseDN: dc=$DOMAIN_NAME,dc=$TOP_LEVEL_DOMAIN
              filter: "(objectClass=user)"
              username: name
              idAttr: name
              emailAttr: name
              nameAttr: name
              preferredUsernameAttr: name
# turn on proxy for interactive desktop apps
host_regex: '[^/]+'
node_uri: '/node'
rnode_uri: '/rnode'
EOF

if [ "$OOD_HTTP" = "true" ]; then
  sed -i "s/ssl: true/ssl: false/" /etc/ood/config/ood_portal.yml

  # Modify the myjobs initializer 
  # change the session store to address CRSF errors when using HTTP
  mkdir -p /etc/ood/config/apps/myjobs/initializers
  cat << EOF >> /etc/ood/config/apps/myjobs/initializers/session_store.rb
  # change the session store to address CRSF errors when using HTTP
  Rails.application.config.session_store :cookie_store, key: '_myjobs_session', secure: false
EOF
fi

mkdir -p /etc/ood/config/ondemand.d
cat << EOF >> /etc/ood/config/ondemand.d/aws-branding.yml
dashboard_title: 'Open OnDemand on AWS'
brand_bg_color: '#ff7f0e'
EOF

# # Tells PUN to look for home directories in EFS
cat << EOF >> /etc/ood/config/nginx_stage.yml
user_home_dir: '/shared/home/%{user}'
EOF


# Set up directories for clusters and interactive desktops
mkdir -p /etc/ood/config/clusters.d
mkdir -p /etc/ood/config/apps/bc_desktop

# Setup shell ping pong
# https://osc.github.io/ood-documentation/latest/customizations.html#enable-and-configure-shell-ping-pong
mkdir -p /etc/ood/config/apps/shell

cat << EOF >> /etc/ood/config/apps/shell/env
# Enable shell ping-ping to keep shell alive
OOD_SHELL_PING_PONG=true
# Timeout in milliseconds before shell is considered inactive
OOD_SHELL_INACTIVE_TIMEOUT_MS=300000
# Maximum duration in milliseconds before shell is considered expired
OOD_SHELL_MAX_DURATION_MS=3600000
EOF


# Setup OOD add user; will add local user for AD user if doesn't exist
touch /var/log/add_user.log
chown apache /var/log/add_user.log
touch /etc/ood/add_user.sh
touch /shared/userlistfile
mkdir -p /shared/home

# Script that we want to use when adding user
cat << EOF >> /etc/ood/add_user.sh
#!/bin/bash
if  id "\$1" &> /dev/null; then
  echo "user \$1 found" >> /var/log/add_user.log
  if [ ! -d "/shared/home/\$1" ] ; then
    echo "user \$1 home folder doesn't exist, create one " >> /var/log/add_user.log
  #  usermod -a -G spack-users \$1
    sudo mkdir -p /shared/home/\$1 >> /var/log/add_user.log
    sudo cp /etc/skel/.bash_profile /shared/home/\$1
    sudo cp /etc/skel/.bashrc /shared/home/\$1
  #  echo "\$1 $(id -u $1)" >> /shared/userlistfile
    sudo chown -R \$1:"Domain Users" /shared/home/\$1 >> /var/log/add_user.log
    sudo su \$1 -c 'ssh-keygen -t rsa -f ~/.ssh/id_rsa -q -P ""'
    sudo su \$1 -c 'cat ~/.ssh/id_rsa.pub > ~/.ssh/authorized_keys'
    sudo chmod 600 /shared/home/\$1/.ssh/*
  fi
fi
echo \$1
EOF


echo "user_map_cmd: '/etc/ood/add_user.sh'" >> /etc/ood/config/ood_portal.yml

# Creates a script where we can re-create local users on PCluster nodes.
# Since OOD uses local users, need those same local users with same UID on PCluster nodes
#cat << EOF >> /shared/copy_users.sh
#while read USERNAME USERID
#do
#    # -u to set UID to match what is set on the head node
#    if [ \$(grep -c '^\$USERNAME:' /etc/passwd) -eq 0 ]; then
#        useradd -M -u \$USERID \$USERNAME -d /shared/home/\$USERNAME
#        usermod -a -G spack-users \$USERNAME
#    fi
#done < "/shared/userlistfile"
#EOF

chmod +x /etc/ood/add_user.sh
#chmod +x /shared/copy_users.sh
#chmod o+w /shared/userlistfile

/opt/ood/ood-portal-generator/sbin/update_ood_portal
systemctl enable httpd
systemctl enable ondemand-dex

# install bin overrides so sbatch executes on remote node
pip3 install sh pyyaml
#create sbatch log
touch /var/log/sbatch.log
chmod 666 /var/log/sbatch.log

# Create this bin overrides script on the box: https://osc.github.io/ood-documentation/latest/installation/resource-manager/bin-override-example.html
cat << EOF >> /etc/ood/config/bin_overrides.py
#!/bin/python3
from getpass import getuser
from select import select
from sh import ssh, ErrorReturnCode
import logging
import os
import re
import sys
import yaml

'''
An example of a "bin_overrides" replacing Slurm "sbatch" for use with Open OnDemand.
Executes sbatch on the target cluster vs OOD node to get around painful experiences with sbatch + EFA.

Requirements:

- $USER must be able to SSH from web node to submit node without using a password
'''
logging.basicConfig(filename='/var/log/sbatch.log', level=logging.INFO)

USER = os.environ['USER']

def run_remote_sbatch(script,host_name, *argv):
  """
  @brief      SSH and submit the job from the submission node

  @param      script (str)  The script
  @parma      host_name (str) The hostname of the head node on which to execute the script
  @param      argv (list<str>)    The argument vector for sbatch

  @return     output (str) The merged stdout/stderr of the remote sbatch call
  """

  output = None

  try:
    result = ssh(
      '@'.join([USER, host_name]),
      '-oBatchMode=yes',  # ensure that SSH does not hang waiting for a password that will never be sent
      '-oUserKnownHostsFile=/dev/null', # ensure that SSH does not try to resolve the hostname of the remote node
      '-oStrictHostKeyChecking=no',
      '/opt/slurm/bin/sbatch',  # the real sbatch on the remote
      *argv,  # any arguments that sbatch should get
      _in=script,  # redirect the script's contents into stdin
      _err_to_out=True  # merge stdout and stderr
    )

    output = result
    logging.info(output)
  except ErrorReturnCode as e:
    output = e
    logging.error(output)
    print(output)
    sys.exit(e.exit_code)

  return output

def load_script():
  """
  @brief      Loads a script from stdin.

  With OOD and Slurm the user's script is read from disk and passed to sbatch via stdin
  https://github.com/OSC/ood_core/blob/5b4d93636e0968be920cf409252292d674cc951d/lib/ood_core/job/adapters/slurm.rb#L138-L148

  @return     script (str) The script content
  """
  # Do not hang waiting for stdin that is not coming
  if not select([sys.stdin], [], [], 0.0)[0]:
    logging.error('No script available on stdin!')
    sys.exit(1)

  return sys.stdin.read()

def get_cluster_host(cluster_name):
  with open(f"/etc/ood/config/clusters.d/{cluster_name}.yml", "r") as stream:
    try:
      config_file=yaml.safe_load(stream)
    except yaml.YAMLError as e:
      logging.error(e)
  return config_file["v2"]["login"]["host"]

def main():
  """
  @brief SSHs from web node to submit node and executes the remote sbatch.
  """
  host_name=get_cluster_host(sys.argv[-1])
  output = run_remote_sbatch(
    load_script(),
    host_name,
    sys.argv[1:]
  )

  print(output)

if __name__ == '__main__':
  main()
EOF

chmod +x /etc/ood/config/bin_overrides.py
#Edit sudoers to allow www-data to add users
echo "apache  ALL=NOPASSWD: /sbin/adduser" >> /etc/sudoers
echo "apache  ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Setup for interactive desktops with PCluster
rm -rf /var/www/ood/apps/sys/bc_desktop/submit.yml.erb
cat << EOF >> /var/www/ood/apps/sys/bc_desktop/submit.yml.erb
batch_connect:
  template: vnc
  websockify_cmd: "/usr/local/bin/websockify"
  set_host: "host=\$(hostname | awk '{print \$1}').<%= cluster%>.pcluster"
EOF
shutdown -r now
