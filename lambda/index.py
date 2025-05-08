import json

def handler(event, context):
    print("File uploaded")
    return {
        "statusCode": 200,
        "body": json.dumps("Success")
    }
