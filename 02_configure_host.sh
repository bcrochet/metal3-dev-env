#!/usr/bin/env bash
set -xe

# shellcheck disable=SC1091
source lib/logging.sh
# shellcheck disable=SC1091
source lib/common.sh

# root needs a private key to talk to libvirt
# See tripleo-quickstart-config/roles/virtbmc/tasks/configure-vbmc.yml
if sudo [ ! -f /root/.ssh/id_rsa_virt_power ]; then
  sudo ssh-keygen -f /root/.ssh/id_rsa_virt_power -P ""
  sudo cat /root/.ssh/id_rsa_virt_power.pub | sudo tee -a /root/.ssh/authorized_keys
fi

ANSIBLE_FORCE_COLOR=true ansible-playbook \
    -e @vm_setup_vars.yml \
    -e "working_dir=$WORKING_DIR" \
    -e "num_nodes=$NUM_NODES" \
    -e "extradisks=$VM_EXTRADISKS" \
    -e "virthost=$HOSTNAME" \
    -e "platform=$NODES_PLATFORM" \
    -e "libvirt_firmware=$LIBVIRT_FIRMWARE" \
    -e "default_memory=$DEFAULT_HOSTS_MEMORY" \
    -e "manage_baremetal=$MANAGE_BR_BRIDGE" \
    -i vm-setup/inventory.ini \
    -b -vvv vm-setup/setup-playbook.yml

# Usually virt-manager/virt-install creates this: https://www.redhat.com/archives/libvir-list/2008-August/msg00179.html
if ! sudo virsh pool-uuid default > /dev/null 2>&1 ; then
    sudo virsh pool-define /dev/stdin <<EOF
<pool type='dir'>
  <name>default</name>
  <target>
    <path>/var/lib/libvirt/images</path>
  </target>
</pool>
EOF
    sudo virsh pool-start default
    sudo virsh pool-autostart default
fi

if [[ $OS == ubuntu ]]; then
  # source ubuntu_bridge_network_configuration.sh
  # shellcheck disable=SC1091
  source ubuntu_bridge_network_configuration.sh
  # shellcheck disable=SC1091
  source disable_apparmor_driver_libvirtd.sh
fi

ANSIBLE_FORCE_COLOR=true ansible-playbook \
    -e "{use_firewalld: $USE_FIREWALLD}" \
    -i vm-setup/inventory.ini \
    -b -vvv vm-setup/firewall.yml

# Switch NetworkManager to internal DNS
if [[ "$MANAGE_BR_BRIDGE" == "y" && $OS == "centos" ]] ; then
  sudo mkdir -p /etc/NetworkManager/conf.d/
  sudo crudini --set /etc/NetworkManager/conf.d/dnsmasq.conf main dns dnsmasq
  if [ "$ADDN_DNS" ] ; then
    echo "server=$ADDN_DNS" | sudo tee /etc/NetworkManager/dnsmasq.d/upstream.conf
  fi
  if systemctl is-active --quiet NetworkManager; then
    sudo systemctl reload NetworkManager
  else
    sudo systemctl restart NetworkManager
  fi
fi

# Needed if we're going to use any locally built images
reg_state=$(sudo "$CONTAINER_RUNTIME" inspect registry --format  "{{.State.Status}}" || echo "error")
if [[ "$reg_state" != "running" ]]; then
 sudo "${CONTAINER_RUNTIME}" rm registry -f || true
 sudo "${CONTAINER_RUNTIME}" run -d -p 5000:5000 --name registry "$DOCKER_REGISTRY_IMAGE"
fi

# Support for building local images
for IMAGE_VAR in $(env | grep "_LOCAL_IMAGE=" | grep -o "^[^=]*") ; do
  IMAGE=${!IMAGE_VAR}

  # Is it a git repo?
  if [[ "$IMAGE" =~ "://" ]] ; then
    REPOPATH=~/${IMAGE##*/}
    # Clone to ~ if not there already
    [ -e "$REPOPATH" ] || git clone "$IMAGE" "$REPOPATH"
    cd "$REPOPATH" || exit
    #shellcheck disable=SC2086
    export $IMAGE_VAR="${IMAGE##*/}:latest"
    #shellcheck disable=SC2086
    export $IMAGE_VAR="192.168.111.1:5000/localimages/${!IMAGE_VAR}"
    sudo "${CONTAINER_RUNTIME}" build -t "${!IMAGE_VAR}" .
    cd - || exit
    sudo "${CONTAINER_RUNTIME}" push --tls-verify=false "${!IMAGE_VAR}" "${!IMAGE_VAR}"
  fi
done

IRONIC_IMAGE=${IRONIC_LOCAL_IMAGE:-$IRONIC_IMAGE}
VBMC_IMAGE=${VBMC_LOCAL_IMAGE:-$VBMC_IMAGE}
SUSHY_TOOLS_IMAGE=${SUSHY_TOOLS_LOCAL_IMAGE:-$SUSHY_TOOLS_IMAGE}

# Start httpd container
sudo "${CONTAINER_RUNTIME}" run -d --net host --privileged --name httpd ${POD_NAME} \
     -v "$IRONIC_DATA_DIR":/shared --entrypoint /bin/runhttpd "${IRONIC_IMAGE}"

# Start vbmc and sushy containers
sudo "${CONTAINER_RUNTIME}" run -d --net host --privileged --name vbmc ${POD_NAME} \
     -v "$WORKING_DIR/virtualbmc/vbmc":/root/.vbmc -v "/root/.ssh":/root/ssh \
     "${VBMC_IMAGE}"

sudo "${CONTAINER_RUNTIME}" run -d --net host --privileged --name sushy-tools ${POD_NAME} \
     -v "$WORKING_DIR/virtualbmc/sushy-tools":/root/sushy -v "/root/.ssh":/root/ssh \
     "${SUSHY_TOOLS_IMAGE}"
