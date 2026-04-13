Connect-AzAccount -Identity
$rg = $env:AKS_RESOURCE_GROUP
$name = $env:AKS_CLUSTER_NAME
Write-Output "Starting AKS cluster $name in $rg"
Start-AzAksCluster -ResourceGroupName $rg -Name $name
