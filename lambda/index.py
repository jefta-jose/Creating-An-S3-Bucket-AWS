import json

def handler(event, context):
    print("File uploaded")
    secret_arn = os.environ.get("SECRETS_MANAGER_ARN") 
    
    print(f"Secret ARN: {secret_arn}")
    
    return {
        "statusCode": 200,
        "body": json.dumps("Success")
    }
