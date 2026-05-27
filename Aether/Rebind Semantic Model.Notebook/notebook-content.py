# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {}
# META }

# CELL ********************

%pip install semantic-link-labs

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

 
from sempy_labs import directlake
 
dataset = 'AetherSM' # Enter the name or ID of your semantic model
workspace = 'Fabric Murder Mystery' # Enter the name or ID of the workspace in which the semantic model resides
source = 'AetherLH' # The name or ID of the lakehouse/warehouse
source_type = "Lakehouse" # Can either be 'Lakehouse' or 'Warehouse'
source_workspace = 'Fabric Murder Mystery' # Enter the name or ID of the workspace in which the lakehouse/warehouse exists
use_sql_endpoint = True
 
directlake.update_direct_lake_model_connection(dataset=dataset, workspace=workspace, source=source, source_type=source_type, source_workspace=source_workspace)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
