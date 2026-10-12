# AWS-CloudX-HoneyPot ðŸ¯

A Cloud-based Honeypot-as-a-Service (HaaS) implementation that collects, parses, stores, and monitors SSH honeypot activity using AWS services.

The project can be run locally using Docker and LocalStack, allowing the AWS infrastructure and event-driven pipeline to be tested without deploying resources to a real AWS account.

## Architecture

SSH Honeypot / Cowrie
        |
        | Log files
        v
+----------------------+
|        Amazon S3     |
|     Honeypot Logs    |
+----------+-----------+
           |
     ObjectCreated
           |
           v
+----------------------+
|       Lambda         |
|   CowrieLogParser    |
+----------+-----------+
           |
     Parsed Events
           |
           v
+----------------------+
|      DynamoDB        |
|      CowrieLogs      |
+----------+-----------+
           |
    DynamoDB Stream
           |
           v
+-----------------------------+
|           Lambda            |
| LogDynamoDBToCloudWatch     |
+-------------+---------------+
              |
              v
       CloudWatch Logs