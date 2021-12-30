import boto3
import json
import os

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.getenv('INCOMING_EMAIL_TABLE'))


def lambda_handler(event, context):
    result = []
    scan_kwargs = {}

    done = False
    start_key = None
    while not done:
        if start_key:
            scan_kwargs['ExclusiveStartKey'] = start_key
        response = table.scan(**scan_kwargs)
        result += response.get('Items', [])
        start_key = response.get('LastEvaluatedKey', None)
        done = start_key is None

    return {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'application/json',
        },
        'body': json.dumps({
            'emails': result
        })
    }
