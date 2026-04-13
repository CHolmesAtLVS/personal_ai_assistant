Connect-AzAccount -Identity
$rg = Get-AutomationVariable -Name 'AKS_RESOURCE_GROUP'
$name = Get-AutomationVariable -Name 'AKS_CLUSTER_NAME'
Write-Output "Starting AKS cluster $name in $rg"
Start-AzAksCluster -ResourceGroupName $rg -Name $name
