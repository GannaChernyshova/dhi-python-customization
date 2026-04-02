# syntax=docker/dockerfile:1
#
# Verification image for the DHI Python customization.
# Uses the customized image that already includes:
#   - hardened curl
#   - BusyBox binaries in /bin
#   - Zscaler CA certificate in the system trust store

FROM demonstrationorg/dhi-python-ann:3.14.3-alpine3.23_zscaler

WORKDIR /app

COPY main.py .

CMD ["python3", "main.py"]
