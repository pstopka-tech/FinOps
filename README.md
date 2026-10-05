#### Azure FinOps Scripts ####

A collection of small PowerShell scripts I created to help identify potential Azure cost savings and cleanup opportunities.
The goal is simple: find potential savings without blindly deleting resources.

## What you'll find here ##

The scripts focus on practical Azure FinOps opportunities such as:

identifying unused or unattached resources
finding potential cleanup candidates
collecting inventory and ownership information
supporting cost optimization investigations

New scripts will be added as I come across other practical FinOps opportunities.

## Approach ##

These scripts are designed for discovery and investigation, not automatic cleanup.
An unused-looking resource may still have a valid reason to exist — for example, it may be reserved for a future deployment, migration or another planned change.
The scripts help identify potential candidates. The final decision should be made by the resource owner.

## Running the scripts ## 

Each script contains its own parameters and usage details.
Most scripts are designed to work across multiple Azure subscriptions and can be used as Azure Automation runbooks.

## Requirements ##
Azure subscription(s)
PowerShell
Az PowerShell modules
Appropriate permissions to read Azure resources and write results to the target Storage Account

For Azure Automation runbooks using Managed Identity, the Automation Account identity also needs the required Azure permissions.

## About ##

These scripts are part of my Practical FinOps for Azure series, where I share small, practical ways to identify and reduce unnecessary Azure costs.
More scripts will be added over time.
