#!/bin/bash
echo "Checking DroidCam..."
if curl -s --connect-timeout 3 http://10.0.0.29:4747/video > /dev/null; then
    echo "DroidCam OK - starting inspection server..."
    cd /home/neo/inspection && .venv/bin/python app.py
else
    echo "ERROR: DroidCam not reachable at 10.0.0.29:4747"
    echo "Open DroidCam on your phone first, then run this again."
fi
