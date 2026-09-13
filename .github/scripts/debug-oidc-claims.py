#!/usr/bin/env python3
"""Print the OIDC identity claims GitHub is presenting to AWS.

Called by the deploy job in .github/workflows/deploy-dev.yml. Use it when the
credentials step fails with "Not authorized to perform
sts:AssumeRoleWithWebIdentity": the "sub" claim printed here is what the deploy
role's trust policy has to accept.

Because the deploy jobs run against a GitHub Environment, the subject is of the
form repo:<owner>/<repo>:environment:<dev|prod> rather than the branch form -
a trust policy written for refs/heads/develop will reject it.

Only the decoded claims are printed - never the token itself, and nothing is
written to disk.

Exits: 0 always is NOT assumed - a missing token endpoint exits 1, and the
calling step sets continue-on-error so a diagnostic never fails a deploy.
"""

import base64
import json
import os
import sys
import urllib.request

INTERESTING = ("sub", "aud", "repository", "repository_owner",
               "repository_owner_id", "repository_id", "ref", "environment")


def main():
    url = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL")
    secret = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
    if not url or not secret:
        print("::error::No OIDC token endpoint in the environment - the job needs "
              "'permissions: id-token: write'.")
        return 1

    request = urllib.request.Request(
        url + "&audience=sts.amazonaws.com",
        headers={"Authorization": "bearer " + secret})
    with urllib.request.urlopen(request) as response:
        token = json.load(response)["value"]

    payload = token.split(".")[1]  # header.payload.signature, base64url, unpadded
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))

    print("Claims GitHub is presenting to AWS:")
    for key in INTERESTING:
        if key in claims:
            print("  %-20s = %s" % (key, claims[key]))
    print()
    print('  The role trust policy must accept the "sub" value above.')
    return 0


if __name__ == "__main__":
    sys.exit(main())
