Connect-AzAccount -Identity
$rg = Get-AutomationVariable -Name 'AKS_RESOURCE_GROUP'
$name = Get-AutomationVariable -Name 'AKS_CLUSTER_NAME'
Write-Output "Stopping AKS cluster $name in $rg"
Stop-AzAksCluster -ResourceGroupName $rg -Name $name -Force
