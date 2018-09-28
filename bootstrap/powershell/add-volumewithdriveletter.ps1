param (
    [Parameter(Mandatory=$true)][string]$KmsKeyArn,
    [Parameter(Mandatory=$true)][string]$TagValueNodeName,
    [Parameter(Mandatory=$true)][string]$VolumeSizeInGb,
    [Parameter(Mandatory=$true)][string]$DriveLetter
)


#Phase one - create volume in AWS and attach to this instance

$AvailabilityZone = (invoke-WebRequest -uri 'http://169.254.169.254/latest/meta-data/placement/availability-zone' -UseBasicParsing).Content
$InstanceId = (invoke-WebRequest -uri 'http://169.254.169.254/latest/meta-data/instance-id' -UseBasicParsing).Content

$Region = $AvailabilityZone.substring(0,$AvailabilityZone.Length-1)
Set-DefaultAWSRegion $Region

Write-Host "I am instance ID $InstanceId."
Write-Host "I am located in Availability Zone $AvailabilityZone."

$NewVolume = New-EC2Volume -AvailabilityZone $AvailabilityZone -Size $VolumeSizeInGb -Encrypted $true -KmsKeyId $KmsKeyArn -VolumeType 'gp2' -region $Region
$VolumeId = $NewVolume.VolumeId

Write-Host "Creating new volume $VolumeId."

do
{
    $VolumeStatus = Get-EC2Volume -VolumeId $VolumeId -Region $Region
    $VolumeStatus.State
    start-sleep -Seconds 10
}
while ($VolumeStatus.State -ne 'available')

#Find next available EC2 Device (xvd*)
$instance = (Get-EC2Instance -InstanceId $InstanceId).Instances
$mappings = ($instance.BlockDeviceMappings).DeviceName
$i = 102 #Iterate ascii alphabet starting at 'f'
$device = "xvd" + [char]$i
While ($mappings -contains "$($device)")
{
    $i++
    $device = "xvd" + [char]$i
}

$AttachVolume = Add-EC2Volume -InstanceId $InstanceId -Device $device -VolumeId $VolumeId

Write-Host "Attaching volume $VolumeId to myself."

do
{
    $VolumeStatus = Get-EC2Volume -VolumeId $VolumeId -Region $Region
    $VolumeStatus.State
    start-sleep -Seconds 10
}
while ($VolumeStatus.State -ne 'in-use')

#Tagging the new volume with all the relevant tags.
Write-Host "Tagging volume $VolumeId."

$Tag = new-object amazon.EC2.Model.Tag
$Tag.Key = "Name"
$Tag.Value = "$($TagValueNodeName) Drive $($DriveLetter) $($InstanceId)"
New-EC2Tag -ResourceId $VolumeId -Tag $Tag | out-null

#sleeping for 30 seconds to allow Windows to catch up
Write-Host "Sleeping for 30 seconds to allow Windows time to see the new drive..."
Start-Sleep 30

#Phase Two - configure disk in Windows

$OfflineDisks = Get-Disk | ? {($_.PartitionStyle –Eq "RAW") -or ($_.IsOffline –Eq $True)}

Write-Host "Configuring the disk in Windows."

$Disk = $OfflineDisks[0]
Write-Host "Found an offline disk: Number" $Disk.Number
$res = Set-Disk –IsOffline $False -Number $Disk.Number
Write-Host "Initialize Disk. Number" $Disk.Number
$res = Initialize-Disk $Disk.Number
Write-Host "Partition Disk. Number $($Disk.Number). Drive $($DriveLetter):"
$res = New-Partition –DiskNumber $Disk.Number -UseMaximumSize -DriveLetter $DriveLetter
Write-Host "Format Drive $($DriveLetter):"
$res = Format-Volume -DriveLetter $DriveLetter -Force -Confirm:$false
Write-Host "Finished preparing drive $($DriveLetter):"

Write-Host "Disk prep completed. Now ensuring the disk is showing up in Windows and is writeable." 

do
{
    try
    {
		$DriveAvailable = $true
        #Check the disk is available and is writeable
		#write out the volume ID to a text file. This is used to delete this volume when the instance is terminated.
        $VolumeId | Out-File "$($DriveLetter):\VolumeId.txt"
    }
    catch [System.Net.WebException],[System.Exception]
    {
        #Windows could be taking its time...
        Write-Host "$DriveLetter Drive not available yet. Waiting for 10 seconds and trying again."
        Start-Sleep -Seconds 10
        $DriveAvailable = $false
    }
}
while ($DriveAvailable -ne $true)
Write-Host "Adding Volume $($VolumeId) to $($DriveLetter): Complete."
