$script:dscModuleName = 'xPSDesiredStateConfiguration'
$script:dscResourceName = 'xServiceSet'

<#
    Please note that these tests are currently dependent on each other.
    They must be run in the order given and if one test fails, subsequent tests will
    also fail.
#>

try
{
    Import-Module -Name DscResource.Test -Force -ErrorAction 'Stop'
}
catch [System.IO.FileNotFoundException]
{
    throw 'DscResource.Test module dependency not found. Please run ".\build.ps1 -Tasks build" first.'
}

$script:testEnvironment = Initialize-TestEnvironment `
    -DSCModuleName $script:dscModuleName `
    -DSCResourceName $script:dscResourceName `
    -ResourceType 'Mof' `
    -TestType 'Integration'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\TestHelpers\CommonTestHelper.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\TestHelpers\DSC_xServiceResource.TestHelper.psm1')

# Begin Testing
try
{
    Describe 'xServiceSet Integration Tests' {
        BeforeAll {
            # Configuration file paths
            $script:confgurationFilePathAllExceptBuiltInAccount = Join-Path -Path $PSScriptRoot -ChildPath 'xServiceSet_AllExceptBuiltInAccount.config.ps1'
            $script:confgurationFilePathBuiltInAccountOnly = Join-Path -Path $PSScriptRoot -ChildPath 'xServiceSet_BuiltInAccountOnly.config.ps1'

            # Create test service binary for service 1
            $script:service1Properties = @{
                Name = 'TestService'
                DisplayName = 'TestDisplayName'
                Description = 'Test service description'
                Dependencies = @( 'winrm' )
                Path = Join-Path -Path $TestDrive -ChildPath 'DscTestService.exe'
            }

            $service1NewExecutableParameters = @{
                ServiceName = $script:service1Properties.Name
                ServiceCodePath = Join-Path -Path $PSScriptRoot -ChildPath 'DscTestService.cs'
                ServiceDisplayName = $script:service1Properties.DisplayName
                ServiceDescription = $script:service1Properties.Description
                ServiceDependsOn = $script:service1Properties.Dependencies -join ', '
                OutputPath = $script:service1Properties.Path
            }

            New-ServiceExecutable @service1NewExecutableParameters

            # Create test service binary for service 2
            $script:service2Properties = @{
                Name = 'TestService2'
                DisplayName = 'NewTestDisplayName'
                Description = 'New test service description'
                Path = Join-Path -Path $TestDrive -ChildPath 'NewDscTestService.exe'
            }

            $service2NewExecutableParameters = @{
                ServiceName = $script:service2Properties.Name
                ServiceCodePath = Join-Path -Path $PSScriptRoot -ChildPath 'DscTestServiceNew.cs'
                ServiceDisplayName = $script:service2Properties.DisplayName
                ServiceDescription = $script:service2Properties.Description
                OutputPath = $script:service2Properties.Path
            }

            New-ServiceExecutable @service2NewExecutableParameters

            $script:testServiceNames = @( $script:service1Properties.Name, $script:service2Properties.Name )
            $script:testServiceExecutables = @( $script:service1Properties.Path, $script:service2Properties.Path )

            # Create new services since xServiceSet cannot
            $newService1Parameters = @{
                Name = $script:service1Properties.Name
                BinaryPathName = $script:service1Properties.Path
                DisplayName = $script:service1Properties.DisplayName
                Description = $script:service1Properties.Description
                DependsOn = $script:service1Properties.Dependencies
            }

            $null = New-Service @newService1Parameters

            $newService2Parameters = @{
                Name = $script:service2Properties.Name
                BinaryPathName = $script:service2Properties.Path
                DisplayName = $script:service2Properties.DisplayName
                Description = $script:service2Properties.Description
            }

            $null = New-Service @newService2Parameters
        }

        AfterAll {
            # Remove any created services
            foreach ($testServiceName in $script:testServiceNames)
            {
                if (Test-ServiceExists -Name $testServiceName)
                {
                    Remove-ServiceWithTimeout -Name $testServiceName
                }
            }
        }

        Context 'Edit all possible properties of one service except BuiltInAccount' {
            Clear-DscLcmConfiguration

            $configData = @{
                AllNodes = @(
                    @{
                        NodeName = 'localhost'
                        PSDscAllowPlainTextPassword = $true
                    }
                )
            }

            $configurationName = 'TestEditOneServiceSet'

            $testAdminCreds = Get-TestAdministratorAccountCredential

            $resourceParameters = @{
                Name = @( $script:service1Properties.Name )
                Ensure = 'Present'
                StartupType = 'Manual'
                Credential =  $testAdminCreds
                State = 'Stopped'
            }

            It 'Should compile and apply the MOF without throwing' {
                {
                    . $script:confgurationFilePathAllExceptBuiltInAccount -ConfigurationName $configurationName
                    & $configurationName -OutputPath $TestDrive -ConfigurationData $configData @resourceParameters
                    Reset-DscLcm
                    Start-DscConfiguration -Path $TestDrive -ErrorAction 'Stop' -Wait -Force
                } | Should -Not -Throw
            }

            $service = Get-Service -Name $resourceParameters.Name[0] -ErrorAction 'SilentlyContinue'
            $serviceCimInstance = Get-CimInstance -ClassName 'Win32_Service' -Filter "Name='$($resourceParameters.Name[0])'" -ErrorAction 'SilentlyContinue'

            It 'Should not have removed service with the specified name' {
                $service | Should -Not -Be $null
                $serviceCimInstance | Should -Not -Be $null

                $service.Name | Should -Be $resourceParameters.Name[0]
                $serviceCimInstance.Name | Should -Be $resourceParameters.Name[0]
            }

            It 'Should have set the service state to the specified state' {
                $service.Status | Should -Be $resourceParameters.State
            }

            It 'Should have set the service startup type to the specified startup type' {
                $serviceCimInstance.StartMode | Should -Be $resourceParameters.StartupType
            }

            It 'Should have set the service start name to the test credential account name' {
                $serviceCimInstance.StartName | Should -Be ".\$($testAdminCreds.UserName.Split('\')[1])"
            }
        }

        Context 'Edit BuiltInAccount of two services' {
            Clear-DscLcmConfiguration

            $configurationName = 'TestEditTwoServiceSet'
            $resourceParameters = @{
                Name = @( $script:service1Properties.Name, $script:service2Properties.Name )
                Ensure = 'Present'
                BuiltInAccount = 'LocalSystem'
            }

            It 'Should compile and apply the MOF without throwing' {
                {
                    . $script:confgurationFilePathBuiltInAccountOnly -ConfigurationName $configurationName
                    & $configurationName -OutputPath $TestDrive @resourceParameters
                    Reset-DscLcm
                    Start-DscConfiguration -Path $TestDrive -ErrorAction 'Stop' -Wait -Force
                } | Should -Not -Throw
            }

            $serviceCount = 1

            foreach ($serviceName in $resourceParameters.Name)
            {
                $service = Get-Service -Name $serviceName -ErrorAction 'SilentlyContinue'
                $serviceCimInstance = Get-CimInstance -ClassName 'Win32_Service' -Filter "Name='$serviceName'" -ErrorAction 'SilentlyContinue'

                It "Should not have removed service $serviceCount" {
                    $service | Should -Not -Be $null
                    $serviceCimInstance | Should -Not -Be $null

                    $service.Name | Should -Be $serviceName
                    $serviceCimInstance.Name | Should -Be $serviceName
                }

                It "Should have set the state  of service $serviceCount to Running (default action of xService)" {
                    $service.Status | Should -Be 'Running'
                }

                It "Should have set the start name of service $serviceCount to the specified built-in account name" {
                    $serviceCimInstance.StartName | Should -Be $resourceParameters.BuiltInAccount
                }

                $serviceCount += 1
            }
        }

        Context 'Remove two services' {
            Clear-DscLcmConfiguration

            $configurationName = 'TestEditOneServiceSet'
            $resourceParameters = @{
                Name = @( $script:service1Properties.Name, $script:service2Properties.Name )
                Ensure = 'Absent'
                BuiltInAccount = 'LocalSystem'
            }

            It 'Should compile and apply the MOF without throwing' {
                {
                    . $script:confgurationFilePathBuiltInAccountOnly -ConfigurationName $configurationName
                    & $configurationName -OutputPath $TestDrive @resourceParameters
                    Reset-DscLcm
                    Start-DscConfiguration -Path $TestDrive -ErrorAction 'Stop' -Wait -Force
                } | Should -Not -Throw
            }

            $serviceCount = 1

            foreach ($serviceName in $resourceParameters.Name)
            {
                $service = Get-Service -Name $serviceName -ErrorAction 'SilentlyContinue'
                $serviceCimInstance = Get-CimInstance -ClassName 'Win32_Service' -Filter "Name='$serviceName'" -ErrorAction 'SilentlyContinue'

                It "Should have removed service $serviceCount" {
                    $service | Should -Be $null
                    $serviceCimInstance | Should -Be $null
                }

                $serviceCount += 1
            }
        }
    }
}
finally
{
    Restore-TestEnvironment -TestEnvironment $script:testEnvironment
}
