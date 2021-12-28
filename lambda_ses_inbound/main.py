import boto3
from datetime import datetime
from email.parser import BytesParser
from email import policy
import os

s3 = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.getenv('INCOMING_EMAIL_TABLE'))


def lambda_handler(event, context):
    ses_notification = event['Records'][0]['ses']
    recipients_array = ses_notification['receipt']['recipients']
    subject = ses_notification['mail']['commonHeaders']['subject']
    message_id = ses_notification['mail']['messageId']

    o = s3.get_object(Bucket=os.getenv('INCOMING_EMAIL_BUCKET'), Key=message_id)
    raw_mail = o['Body'].read()
    msg = BytesParser(policy=policy.SMTP).parsebytes(raw_mail)

    body = ''

    try:
        plain = msg.get_body(preferencelist=('plain'))
        plain = ''.join(plain.get_content().splitlines(keepends=True))
        body = '' if plain is None else plain
    except:
        print('Incoming message does not have an plain text part - skipping this part.')

    table.put_item(
        Item={
            'messageId': message_id,
            'emailAddress': recipients_array[0],
            'receivedAt': datetime.utcnow().isoformat(),
            'subject': subject,
            'body': body,
        }
    )

    return None
