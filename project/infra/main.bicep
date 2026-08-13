/*
  main.bicep
  ------------------------------------------------------------------
  Reference 3-tier architecture on Azure for the Aabha reservation app.

  Tier 1 (edge)     : Application Gateway (public IP, WAF-capable SKU)
  Tier 2 (app/web)  : VMSS running Apache + PHP, in a private subnet,
                       only reachable through the Application Gateway,
                       autoscaled on CPU.
  Tier 3 (data)     : Azure Database for MySQL Flexible Server, VNet-
                       injected into an isolated private subnet with
                       no public inbound access, outbound internet
                       (patching, etc.) via a NAT Gateway.

  Network layout (10.0.0.0/16):
    snet-appgw   10.0.0.0/26   Application Gateway
    snet-web     10.0.1.0/24   VMSS (app tier)
    snet-data    10.0.2.0/24   MySQL Flexible Server (data tier)
    AzureBastionSubnet 10.0.3.0/26   Bastion (admin access, no public SSH)

  This is written as a single file for readability as a learning project.
  In a real environment, split into modules (network / compute / data)
  and move secrets (admin passwords, DB passwords) into Key Vault with
  a Key Vault reference instead of plain secure parameters.
*/

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Short name used as a prefix for resource names')
param projectName string = 'aabha'

@description('Environment tag, e.g. dev / staging / prod')
param environmentName string = 'dev'

@description('Admin username for the VMSS Linux instances')
param adminUsername string = 'azureuser'

@description('SSH public key used to admin the VMSS instances (via Bastion, no public SSH)')
@secure()
param adminSshPublicKey string

@description('Administrator login for the MySQL Flexible Server')
param mysqlAdminUsername string = 'mysqladmin'

@description('Administrator password for the MySQL Flexible Server')
@secure()
param mysqlAdminPassword string

@description('Password for the least-privilege application DB user (restaurant_app) that the PHP app uses at runtime')
@secure()
param appDbPassword string

@description('VM size for the app-tier VMSS instances')
param vmssSku string = 'Standard_B2s'

@description('Initial VMSS instance count')
@minValue(2)
param vmssInstanceCount int = 2

@description('Minimum VMSS instance count for autoscale')
param vmssMinCount int = 2

@description('Maximum VMSS instance count for autoscale')
param vmssMaxCount int = 6

@description('MySQL Flexible Server SKU name')
param mysqlSkuName string = 'Standard_B1ms'

@description('MySQL Flexible Server SKU tier')
param mysqlSkuTier string = 'Burstable'

var namePrefix = '${projectName}-${environmentName}'
var tags = {
  project: projectName
  environment: environmentName
  tier: 'multi-tier-demo'
}

// ---------------------------------------------------------------------
// App code, embedded at deploy time from the sibling frontend/backend
// folders so the whole repo ships as one deployable unit.
// ---------------------------------------------------------------------

var indexHtmlB64  = base64(loadTextContent('../frontend/index.html'))
var configPhpB64  = base64(loadTextContent('../backend/config.php'))
var dbPhpB64      = base64(loadTextContent('../backend/db.php'))
var bookingPhpB64 = base64(loadTextContent('../backend/api/booking.php'))
var healthPhpB64  = base64(loadTextContent('../backend/api/health.php'))

// ---------------------------------------------------------------------
// Networking: VNet + subnets
// ---------------------------------------------------------------------

resource nsgAppGw 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${namePrefix}-nsg-appgw'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTP-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'Allow-GatewayManager-Inbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer-Inbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgWeb 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${namePrefix}-nsg-web'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        // Only the Application Gateway subnet may reach the app tier on 80.
        // The public internet never talks to snet-web directly.
        name: 'Allow-HTTP-From-AppGw'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/26'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgData 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${namePrefix}-nsg-data'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        // Only the app-tier subnet may reach MySQL. Nothing else, ever.
        name: 'Allow-MySQL-From-Web'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.1.0/24'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3306'
        }
      }
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-All-Other-Inbound'
        properties: {
          priority: 4090
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource natGwPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${namePrefix}-pip-natgw'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-09-01' = {
  name: '${namePrefix}-natgw-data'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      { id: natGwPublicIp.id }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${namePrefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/16' ]
    }
    subnets: [
      {
        name: 'snet-appgw'
        properties: {
          addressPrefix: '10.0.0.0/26'
          networkSecurityGroup: { id: nsgAppGw.id }
        }
      }
      {
        name: 'snet-web'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: { id: nsgWeb.id }
        }
      }
      {
        name: 'snet-data'
        properties: {
          addressPrefix: '10.0.2.0/24'
          networkSecurityGroup: { id: nsgData.id }
          natGateway: { id: natGateway.id }
          delegations: [
            {
              name: 'mysqlFlexDelegation'
              properties: {
                serviceName: 'Microsoft.DBforMySQL/flexibleServers'
              }
            }
          ]
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.0.3.0/26'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------
// Bastion: admin access to VMSS / data tier without any public SSH
// ---------------------------------------------------------------------

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${namePrefix}-pip-bastion'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: '${namePrefix}-bastion'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: '${vnet.id}/subnets/AzureBastionSubnet' }
          publicIPAddress: { id: bastionPublicIp.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------
// Data tier: private DNS zone + MySQL Flexible Server (VNet-injected)
// ---------------------------------------------------------------------

resource mysqlPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.mysql.database.azure.com'
  location: 'global'
  tags: tags
}

resource mysqlDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: mysqlPrivateDnsZone
  name: '${namePrefix}-mysql-dns-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource mysqlServer 'Microsoft.DBforMySQL/flexibleServers@2023-06-30' = {
  name: '${namePrefix}-mysql'
  location: location
  tags: tags
  sku: {
    name: mysqlSkuName
    tier: mysqlSkuTier
  }
  properties: {
    administratorLogin: mysqlAdminUsername
    administratorLoginPassword: mysqlAdminPassword
    version: '8.0.21'
    storage: {
      storageSizeGB: 32
      autoGrow: 'Enabled'
    }
    network: {
      delegatedSubnetResourceId: '${vnet.id}/subnets/snet-data'
      privateDnsZoneResourceId: mysqlPrivateDnsZone.id
    }
    highAvailability: {
      mode: 'Disabled' // set to 'ZoneRedundant' for production
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
  }
  dependsOn: [
    mysqlDnsZoneVnetLink
  ]
}

// ---------------------------------------------------------------------
// Edge tier: public IP + Application Gateway
// ---------------------------------------------------------------------

resource appGwPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${namePrefix}-pip-appgw'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

var appGwName = '${namePrefix}-agw'
var backendPoolName = 'pool-web'
var httpSettingsName = 'https-settings-web'
var frontendPortName = 'port-80'
var listenerName = 'listener-http'
var routingRuleName = 'rule-http'
var probeName = 'probe-health'

resource appGw 'Microsoft.Network/applicationGateways@2023-09-01' = {
  name: appGwName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
    }
    autoscaleConfiguration: {
      minCapacity: 2
      maxCapacity: 5
    }
    gatewayIPConfigurations: [
      {
        name: 'gwipconfig'
        properties: {
          subnet: { id: '${vnet.id}/subnets/snet-appgw' }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'frontendip'
        properties: {
          publicIPAddress: { id: appGwPublicIp.id }
        }
      }
    ]
    frontendPorts: [
      {
        name: frontendPortName
        properties: { port: 80 }
      }
    ]
    backendAddressPools: [
      {
        name: backendPoolName
        properties: {} // populated dynamically as VMSS instances register
      }
    ]
    probes: [
      {
        name: probeName
        properties: {
          protocol: 'Http'
          path: '/api/health.php'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: httpSettingsName
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          probe: { id: resourceId('Microsoft.Network/applicationGateways/probes', appGwName, probeName) }
        }
      }
    ]
    httpListeners: [
      {
        name: listenerName
        properties: {
          frontendIPConfiguration: { id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'frontendip') }
          frontendPort: { id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, frontendPortName) }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: routingRuleName
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: { id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, listenerName) }
          backendAddressPool: { id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, backendPoolName) }
          backendHttpSettings: { id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, httpSettingsName) }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------
// App tier: VMSS running Apache + PHP, cloud-init bootstraps the app
// ---------------------------------------------------------------------

var cloudInit = '''#cloud-config
package_update: true
packages:
  - apache2
  - php
  - php-mysql
  - libapache2-mod-php

write_files:
  - path: /var/www/html/index.html
    encoding: b64
    content: ${indexHtmlB64}
    owner: www-data:www-data
  - path: /var/www/html/config.php
    encoding: b64
    content: ${configPhpB64}
    owner: www-data:www-data
  - path: /var/www/html/db.php
    encoding: b64
    content: ${dbPhpB64}
    owner: www-data:www-data
  - path: /var/www/html/api/booking.php
    encoding: b64
    content: ${bookingPhpB64}
    owner: www-data:www-data
  - path: /var/www/html/api/health.php
    encoding: b64
    content: ${healthPhpB64}
    owner: www-data:www-data
  - path: /etc/apache2/conf-available/db-env.conf
    permissions: '0644'
    content: |
      SetEnv APP_ENV "production"
      SetEnv DB_HOST "${mysqlServer.properties.fullyQualifiedDomainName}"
      SetEnv DB_PORT "3306"
      SetEnv DB_NAME "restaurant_db"
      SetEnv DB_USER "restaurant_app"
      SetEnv DB_PASS "${appDbPassword}"

runcmd:
  - mkdir -p /var/www/html/api
  - a2enmod env
  - a2enconf db-env
  - chown -R www-data:www-data /var/www/html
  - systemctl enable apache2
  - systemctl restart apache2
'''

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: '${namePrefix}-vmss-web'
  location: location
  tags: tags
  sku: {
    name: vmssSku
    tier: 'Standard'
    capacity: vmssInstanceCount
  }
  properties: {
    overprovision: true
    upgradePolicy: {
      mode: 'Automatic'
    }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: 'webvm'
        adminUsername: adminUsername
        customData: base64(cloudInit)
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: adminSshPublicKey
              }
            ]
          }
        }
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          managedDisk: { storageAccountType: 'Standard_LRS' }
        }
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'nic-web'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfig-web'
                  properties: {
                    subnet: { id: '${vnet.id}/subnets/snet-web' }
                    applicationGatewayBackendAddressPools: [
                      { id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, backendPoolName) }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
    }
  }
  dependsOn: [
    appGw
  ]
}

// ---------------------------------------------------------------------
// Autoscale: scale the app tier on CPU utilization
// ---------------------------------------------------------------------

resource vmssAutoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = {
  name: '${namePrefix}-vmss-autoscale'
  location: location
  tags: tags
  properties: {
    enabled: true
    targetResourceUri: vmss.id
    profiles: [
      {
        name: 'default-cpu-profile'
        capacity: {
          minimum: string(vmssMinCount)
          maximum: string(vmssMaxCount)
          default: string(vmssInstanceCount)
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 70
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 25
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
        ]
      }
    ]
  }
}

// ---------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------

output appGatewayPublicIp string = appGwPublicIp.properties.ipAddress
output mysqlServerFqdn string = mysqlServer.properties.fullyQualifiedDomainName
output vmssName string = vmss.name
output bastionName string = bastion.name
