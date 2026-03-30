# Advanced Network Segmentation and Perimeter Security Laboratory

## 1. Laboratory Objectives
The primary objective of this laboratory is to design and implement a secure network architecture using a unified Edge-Firewall. This configuration provides network segmentation, Network Address Translation (NAT), and perimeter security for multiple virtual environments.

Upon completion of this guide, students will have established:
*   A multi-segment network topology (WAN, DMZ, and Internal).
*   A centralized Edge-Firewall for traffic inspection and address translation.
*   Secure communication paths for isolated client segments.

## 2. Infrastructure Requirements (VMware ESXi)
The following virtual networking components must be configured within the VMware ESXi environment prior to virtual machine deployment.

### 2.1 Virtual Switches
*   **vSwitch0:** Utilizes a physical uplink for external connectivity (WAN).
*   **vSwitch-DMZ:** A standard switch without a physical uplink, used for isolated public-facing services.
*   **vSwitch-INT:** A standard switch without a physical uplink, used for private internal network segments.

### 2.2 Port Groups
Ensure each port group is associated with the correct virtual switch and assigned a VLAN ID of 0 (untagged).
*   **PG-WAN:** Associated with `vSwitch0`.
*   **PG-DMZ:** Associated with `vSwitch-DMZ`.
*   **PG-INT:** Associated with `vSwitch-INT`.

## 3. Edge-Firewall Configuration
The Edge-Firewall acts as the gateway for all internal segments and manages external communication.

### 3.1 Interface Mapping
Assign three network adapters to the Edge-Firewall virtual machine in the following order:
*   **Adapter 1 (ens160):** Assigned to `PG-WAN`.
*   **Adapter 2 (ens192):** Assigned to `PG-DMZ`.
*   **Adapter 3 (ens224):** Assigned to `PG-INT`.

### 3.2 Network Addressing (Netplan)
Configure the interfaces using a static IP assignment. Edit the configuration file located at `/etc/netplan/01-netcfg.yaml`.

```yaml
network:
  version: 2
  ethernets:
    ens160: # External WAN Interface
      addresses:
        - 172.24.131.210/24
      gateway4: 172.24.131.1
      nameservers:
        addresses: [172.24.131.254, 8.8.8.8]

    ens192: # DMZ Segment Interface
      addresses:
        - 192.168.20.1/24

    ens224: # Internal Segment Interface
      addresses:
        - 192.168.30.1/24
```
Apply the configuration:
`sudo netplan apply`

### 3.3 Routing and Network Address Translation
Enable the Linux kernel's IPv4 forwarding and configure `iptables` to perform MASQUERADE (NAT) on the WAN interface.

**1. Enable IP Forwarding:**
`sudo sysctl -w net.ipv4.ip_forward=1`

**2. Configure NAT:**
`sudo iptables -t nat -A POSTROUTING -o ens160 -j MASQUERADE`

**3. Configure Forwarding Policies:**
Allow traffic from the DMZ and Internal segments to the WAN interface:
`sudo iptables -A FORWARD -i ens192 -o ens160 -j ACCEPT`
`sudo iptables -A FORWARD -i ens224 -o ens160 -j ACCEPT`

Allow established and related return traffic to penetrate the firewall:
`sudo iptables -A FORWARD -i ens160 -o ens192 -m state --state RELATED,ESTABLISHED -j ACCEPT`
`sudo iptables -A FORWARD -i ens160 -o ens224 -m state --state RELATED,ESTABLISHED -j ACCEPT`

## 4. Client Host Configuration
Hosts within the DMZ and Internal segments must use the Edge-Firewall as their default gateway.

### 4.1 DMZ Host (e.g., Web Server)
Assign the following network parameters to any host residing in the DMZ segment:
*   **IP Address:** 192.168.20.10/24
*   **Gateway:** 192.168.20.1 (Edge-Firewall DMZ IP)
*   **DNS:** 8.8.8.8

### 4.2 Internal Host (e.g., Application Server)
Assign the following network parameters to any host residing in the Internal segment:
*   **IP Address:** 192.168.30.10/24
*   **Gateway:** 192.168.30.1 (Edge-Firewall Internal IP)
*   **DNS:** 8.8.8.8

## 5. System Validation Procedures
Methodically verify the network connectivity to ensure the firewall is performing translation and routing correctly.

### 5.1 Edge-Firewall Diagnostics
Verify WAN and Internal connectivity from the firewall console:
1.  `ping 172.24.131.1` (Verify University Gateway)
2.  `ping 192.168.20.10` (Verify DMZ Host)
3.  `ping 8.8.8.8` (Verify External DNS)

### 5.2 Client Diagnostics (DMZ/Internal)
Verify end-to-end connectivity from a client host:
1.  `ping 192.168.x.1` (Verify Firewall Gateway reaching)
2.  `ping 8.8.8.8` (Verify WAN/NAT translation)

## 6. Troubleshooting and Verification
If a client host cannot reach the internet, perform the following checks on the Edge-Firewall:
*   **Forwarding Verification:** Use `sudo iptables -L FORWARD -v -n` to check if packet counters are incrementing.
*   **NAT Verification:** Use `sudo iptables -t nat -L -v -n` to confirm the MASQUERADE rule is being utilized.
*   **Route Verification:** Ensure `ip route` on the firewall shows a default route via `172.24.131.1`.
