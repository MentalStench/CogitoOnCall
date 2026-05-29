Application Name: Cogito On Call Helper
Use Powershell 7
App will be a .ps1 file that will display a .net form. Either WPF or WinForms
There will be a .json configuration file listing SQL Server Instances, SQL Server Agent jobs for each instance, the schedule each job runs on, and an estimated time of completion for each job.
The schedule will be for specific days or "daily", etc.
The app needs to use the configuration file to connect to each sql server instance and make sure the job either ran and finished as expected, or if there was an error when it ran.
The app also needs to check the last run status of each enabled job on each sql server instance in the schedule to make sure the last run was successful.
The app's UI needs to clearly display each instance's job information, status, etc. so the on call person can quickly see what needs to be worked on.
When the app starts, there should be a button that says "Scan" that will kick off reading the config file and doing its work.
