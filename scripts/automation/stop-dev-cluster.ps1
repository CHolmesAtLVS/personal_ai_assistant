Connect-AzAccount -Identity
$rg = $env:AKS_RESOURCE_GROUP
$name = $env:AKS_CLUSTER_NAME
Write-Output "Stopping AKS cluster $name in $rg"
Stop-AzAksCluster -ResourceGroupName $rg -Name $name -Force
