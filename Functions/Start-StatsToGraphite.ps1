Function Start-StatsToGraphite
{
<#
    .Synopsis
        Starts the loop which sends Windows Performance Counters to Graphite.

    .Description
        Starts the loop which sends Windows Performance Counters to Graphite. Configuration is all done from the StatsToGraphiteConfig.xml file.

    .Parameter Verbose
        Provides Verbose output which is useful for troubleshooting

    .Parameter TestMode
        Metrics that would be sent to Graphite is shown, without sending the metric on to Graphite.

    .Parameter ExcludePerfCounters
        Excludes Performance counters defined in XML config

    .Parameter SqlMetrics
        Includes SQL Metrics defined in XML config

    .Example
        PS> Start-StatsToGraphite

        Will start the endless loop to send stats to Graphite

    .Example
        PS> Start-StatsToGraphite -Verbose

        Will start the endless loop to send stats to Graphite and provide Verbose output.

    .Example
        PS> Start-StatsToGraphite -SqlMetrics

        Sends perf counters & sql metrics

    .Example
        PS> Start-StatsToGraphite -SqlMetrics -ExcludePerfCounters

        Sends only sql metrics

    .Notes
        NAME:      Start-StatsToGraphite
        AUTHOR:    Matthew Hodgkins
        WEBSITE:   http://www.hodgkins.net.au
#>
    [CmdletBinding()]
    Param
    (
        # Enable Test Mode. Metrics will not be sent to Graphite
        [Parameter(Mandatory = $false)]
        [switch]$TestMode,
        [switch]$ExcludePerfCounters = $false,
        [switch]$SqlMetrics = $false
    )

    # Run The Load XML Config Function
    $configFileLastWrite = (Get-Item -Path $configPath).LastWriteTime
    $Config = Import-XMLConfig -ConfigPath $configPath
	
	
	$modules = @( Get-ChildItem ($PSScriptRoot + "\plugins\*.ps1") | ForEach-Object { . $_.FullName} )
	$plugins = $modules | %{ $_.Init()}

	foreach ($plugin in $plugins)
	{
		$configureScriptBlock = 
		{
		param($config) 
		$ConfigSectionName = $this.ConfigSectionName
		
			if ([bool]($config.ModulesConfigs.SelectNodes($ConfigSectionName)))
			{
				if ($config.ModulesConfigs.$ConfigSectionName.HasAttribute("Enabled"))
				{
				
					if ($config.ModulesConfigs.$ConfigSectionName.GetAttribute("Enabled").ToLower() -eq 'true')
					{
						Write-Verbose $ConfigSectionName
						$this.Config = $config.ModulesConfigs.$ConfigSectionName
						Write-Verbose "Config metric path $($config.MetricPath)"
						Write-Verbose "Config node host name $($config.NodeHostName)"
						$this.MetricPath = $config.MetricPath
						$this.NodeHostName = $config.NodeHostName
						
						if ($config.ModulesConfigs.$ConfigSectionName.HasAttribute("CustomPrefix"))
						{
							$this.MetricPath = $config.ModulesConfigs.$ConfigSectionName.GetAttribute("CustomPrefix")
						}
						if ($config.ModulesConfigs.$ConfigSectionName.HasAttribute("CustomNodeHostName"))
						{
							$this.NodeHostName = $config.ModulesConfigs.$ConfigSectionName.GetAttribute("CustomNodeHostName")
						}
						$this.Enabled = $true
					} 
					else
					{
						$this.Enabled = $false
					}
				}

			} 
			else
			{
				$this.Enabled = $false
			}
		}
	
		$memberParam = @{
		MemberType = "ScriptMethod"
		InputObject = $plugin
		Name = "Configure"
		Value = $configureScriptBlock
		}
		Add-Member @memberParam
	}
 

	foreach ($plugin in $plugins)
	{
		$plugin.Configure($Config)
	}
    
	# Get Last Run Time
    $sleep = 0

	
	
    # Start Endless Loop
    while ($true)
    {
        # Loop until enough time has passed to run the process again.
        if($sleep -gt 0) {
            Start-Sleep -Milliseconds $sleep
        }

        # Used to track execution time
        $iterationStopWatch = [System.Diagnostics.Stopwatch]::StartNew()

        $nowUtc = [datetime]::UtcNow

        # Round Time to Nearest Time Period
        $nowUtc = $nowUtc.AddSeconds(- ($nowUtc.Second % $Config.MetricSendIntervalSeconds))

        $metricsToSend = @{}

		foreach ($plugin in $plugins)
		{
			Write-Verbose "Plugin name: $($plugin.PluginName)"
			Write-Verbose "Plugin enabled: $($plugin.enabled)"
			Write-Verbose "Plugin host name: $($plugin.NodeHostName)"
			Write-Verbose "Plugin host name: $($plugin.NodeHostName)"
			Write-Verbose "Plugin host metric path: $($plugin.MetricPath)"
			
			
			$getMetricsStopWatch = [System.Diagnostics.Stopwatch]::StartNew()
			$samples = $plugin.GetMetrics()
			$getMetricsStopWatch.Stop()
			Write-Verbose "Got metrics for $($plugin.PluginName) plugin: $($getMetricsStopWatch.Elapsed.TotalSeconds) seconds."
				
			foreach ($sample in $samples)
			{
				
				
				
                if ($Config.ShowOutput)
                {
                    Write-Verbose "Sample Name: $($sample.Path)"
                }
				 # Create Stopwatch for Filter Time Period
                $filterStopWatch = [System.Diagnostics.Stopwatch]::StartNew()

                # Check if there are filters or not
                if ([string]::IsNullOrEmpty($Config.Filters) -or $sample.Path -notmatch [regex]$Config.Filters)
                {
                    # Run the sample path through the ConvertTo-GraphiteMetric function
                    $cleanNameOfSample = ConvertTo-GraphiteMetric -MetricToClean $sample.Path -HostName $plugin.NodeHostName -MetricReplacementHash $Config.MetricReplace

                    # Build the full metric path
                    $metricPath = $plugin.MetricPath + '.' + $cleanNameOfSample

                    $metricsToSend[$metricPath] = $sample.Value
                }
                else
                {
                    Write-Verbose "Filtering out Sample Name: $($sample.Path) as it matches something in the filters."
                }

                $filterStopWatch.Stop()

                Write-Verbose "Job Execution Time To Get to Clean Metrics: $($filterStopWatch.Elapsed.TotalSeconds) seconds."
				
			}
		} 

        # Send To Graphite Server

        $sendBulkGraphiteMetricsParams = @{
            "CarbonServer" = $Config.CarbonServer
            "CarbonServerPort" = $Config.CarbonServerPort
            "Metrics" = $metricsToSend
            "DateTime" = $nowUtc
            "UDP" = $Config.SendUsingUDP
            "Verbose" = $Config.ShowOutput
            "TestMode" = $TestMode
        }

        Send-BulkGraphiteMetrics @sendBulkGraphiteMetricsParams

        # Reloads The Configuration File After the Loop so new counters can be added on the fly
        if((Get-Item $configPath).LastWriteTime -gt (Get-Date -Date $configFileLastWrite)) {
			$configFileLastWrite = (Get-Item -Path $configPath).LastWriteTime
			$Config = Import-XMLConfig -ConfigPath $configPath
			
				
				
				$modules = @( Get-ChildItem ($PSScriptRoot + "\plugins\*.ps1") | ForEach-Object { . $_.FullName} )
				$plugins = $modules | %{ $_.Init()}
			
				foreach ($plugin in $plugins)
				{
					$configureScriptBlock = 
					{
					param($config) 
					$ConfigSectionName = $this.ConfigSectionName
					
						if ([bool]($config.ModulesConfigs.SelectNodes($ConfigSectionName)))
						{
							if ($config.ModulesConfigs.$ConfigSectionName.HasAttribute("Enabled"))
							{
							
								if ($config.ModulesConfigs.$ConfigSectionName.GetAttribute("Enabled").ToLower() -eq 'true')
								{
									Write-Verbose $ConfigSectionName
									$this.Config = $config.ModulesConfigs.$ConfigSectionName
									Write-Verbose "Config metric path $($config.MetricPath)"
									Write-Verbose "Config node host name $($config.NodeHostName)"
									$this.MetricPath = $config.MetricPath
									$this.NodeHostName = $config.NodeHostName
									
									if ($config.ModulesConfigs.$ConfigSectionName.HasAttribute("CustomPrefix"))
									{
										$this.MetricPath = $config.ModulesConfigs.$ConfigSectionName.GetAttribute("CustomPrefix")
									}
									if ($config.ModulesConfigs.$ConfigSectionName.HasAttribute("CustomNodeHostName"))
									{
										$this.NodeHostName = $config.ModulesConfigs.$ConfigSectionName.GetAttribute("CustomNodeHostName")
									}
									$this.Enabled = $true
								} 
								else
								{
									$this.Enabled = $false
								}
							}
			
						} 
						else
						{
							$this.Enabled = $false
						}
					}
				
					$memberParam = @{
					MemberType = "ScriptMethod"
					InputObject = $plugin
					Name = "Configure"
					Value = $configureScriptBlock
					}
					Add-Member @memberParam
				}
	
			foreach ($plugin in $plugins)
			{
				$plugin.Configure($Config)
			}
        }

        $iterationStopWatch.Stop()
        $collectionTime = $iterationStopWatch.Elapsed
        $sleep = $Config.MetricTimeSpan.TotalMilliseconds - $collectionTime.TotalMilliseconds
        if ($Config.ShowOutput)
        {
            # Write To Console How Long Execution Took
            $VerboseOutPut = 'Total Loop time: ' + $collectionTime.TotalSeconds + ' seconds'
            Write-Output $VerboseOutPut
        }
    }
}