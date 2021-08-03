#!/bin/bash

# TODO: This script uses bash-specific features. Would be nice to make it more
#       portable.

HELP="This script converts the given image to PNG and sends it to the terminal
in chunks. On success it outputs characters that can be used to display
this image. Note that it will use a single line of the output to display
uploading progress.

  Usage:
    $(basename $0) [OPTIONS] IMAGE_FILE

  Options:
    -c N, --columns N
        The number of columns for the image.
    -r N, --rows N
        The number of rows for the image.
    -a, --append
        Do not clear the output file (the one specified with -o).
    -o FILE, --output FILE
        Use FILE to output the characters representing the image instead of
        stdout.
    -e FILE, --err FILE
        Use FILE to output error messages instead of stderr.
    -l FILE, --log FILE
        Enable logging and write logs to FILE.
    -f FILE, --file FILE
        The image file (but you can specify it as a positional argument).
    --noesc
        Do not issue the escape codes representing row numbers (encoded as
        foreground color).
    -h
        Show this message
"

# Exit the script on keyboard interrupt
trap "exit 1" INT

COLS=""
ROWS=""
FILE=""
OUT="/dev/stdout"
ERR="/dev/stderr"
LOG=""
NOESC=""
APPEND=""

# A utility function to print logs
echolog() {
    if [[ -n "$LOG" ]]; then
        echo "$(date +%s.%3N) $1" >> "$LOG"
    fi
}

# A utility function to display what the script is doing.
echostatus() {
    echolog "$1"
    # clear the current line
    echo -en "\033[2K\r"
    # And display the status
    echo -n "$1"
}

# Display an error message, both as the status and to $ERR.
# TODO: This causes double error messages if ERR is stderr but I'm too lazy.
echoerr() {
    echostatus "$1"
    echo "$1" >> "$ERR"
}

# Parse the command line.
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--columns)
            COLS="$2"
            shift
            shift
            ;;
        -r|--rows)
            ROWS="$2"
            shift
            shift
            ;;
        -a|--append)
            APPEND="1"
            shift
            ;;
        -o|--output)
            OUT="$2"
            shift
            shift
            ;;
        -e|--err)
            ERR="$2"
            shift
            shift
            ;;
        -l|--log)
            LOG="$2"
            shift
            shift
            ;;
        -h|--help)
            echo "$HELP"
            exit 0
            ;;
        -f|--file)
            if [[ -n "$FILE" ]]; then
                echoerr "Multiple image files are not supported"
                exit 1
            fi
            FILE="$2"
            shift
            shift
            ;;
        --noesc)
            NOESC=1
            shift
            ;;
        -*)
            echoerr "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -n "$FILE" ]]; then
                echoerr "Multiple image files are not supported: $FILE and $1"
                exit 1
            fi
            FILE="$1"
            shift
            ;;
    esac
done

# If columns and rows are not specified, use some reasonable defaults.
if [[ -z "$COLS" ]]; then
    COLS=50
fi

if [[ -z "$ROWS" ]]; then
    ROWS=15
fi

echolog "Image size columns: $COLS, rows: $ROWS"

# Create a temporary directory to store the chunked image.
TMPDIR="$(mktemp -d)"

if [[ ! "$TMPDIR" || ! -d "$TMPDIR" ]]; then
    echoerr "Can't create a temp dir"
    exit 1
fi

# We need to disable echo, otherwise the response from the terminal containing
# the image id will get echoed. We will restore the terminal settings on exit
# unless we get brutally killed.
stty_orig=`stty -g`
stty -echo
# Disable ctrl-z. Pressing ctrl-z during image uploading may cause some horrible
# issues otherwise.
stty susp undef

# Utility to read response from the terminal that we don't need anymore. (If we
# don't read it it may end up being displayed which is not pretty).
consume_errors() {
    while read -r -d '\' -t 0.1 TERM_RESPONSE; do
        echolog "Consuming unneeded response: $(sed 's/\x1b/^[/g' <<< "$TERM_RESPONSE")"
    done
}

# On exit restore terminal settings, consume possible errors from the terminal
# and remove the temporary directory.
cleanup() {
    consume_errors
    stty $stty_orig
    rm $TMPDIR/chunk_* 2> /dev/null
    rm $TMPDIR/image* 2> /dev/null
    rmdir $TMPDIR || echolog "Could not remove $TMPDIR"
}

# Register the cleanup function to be called on the EXIT signal.
trap cleanup EXIT TERM

# Check if the file exists.
if ! [[ -f "$FILE" ]]; then
    echoerr "File not found: $FILE (pwd: $(pwd))"
    exit 1
fi

#####################################################################
# Helper functions
#####################################################################

# Functions to emit the start and the end of a graphics command.
if [[ -n "$TMUX" ]] && [[ "$TERM" =~ "screen" ]]; then
    # If we are in tmux we have to wrap the command in Ptmux.
    start_gr_command() {
        echo -en '\ePtmux;\e\e_G'
    }
    end_gr_command() {
        echo -en '\e\e\\\e\\'
    }
else
    start_gr_command() {
        echo -en '\e_G'
    }
    end_gr_command() {
        echo -en '\e\\'
    }
fi

# Send a graphics command with the correct start and end
gr_command() {
    start_gr_command
    echo -en "$1"
    end_gr_command
    if [[ -n "$LOG" ]]; then
        local GR_COMMAND="$(start_gr_command)$(echo -en "$1")$(end_gr_command)"
        echolog "SENDING COMMAND: $(sed 's/\x1b/^[/g' <<< "$GR_COMMAND")"
    fi
}

# Show the invalid terminal response message.
invalid_terminal_response() {
    # Replace control characters with '?'.
    echoerr "Invalid terminal response: $(sed 's/\x1b/^[/g' <<< "$TERM_RESPONSE")"
}

# Get a response from the terminal and store it in TERM_RESPONSE,
# aborts the script if there is no response.
get_terminal_response() {
    TERM_RESPONSE=""
    # -r means backslash is part of the line
    # -d '\' means \ is the line delimiter
    # -t 0.5 is timeout
    if ! read -r -d '\' -t 2 TERM_RESPONSE; then
        if [[ -z "$TERM_RESPONSE" ]]; then
            echoerr "No response from terminal"
        else
            invalid_terminal_response
        fi
        exit 1
    fi
    echolog "TERM_RESPONSE: $(sed 's/\x1b/^[/g' <<< "$TERM_RESPONSE")"
}


# Output characters representing the image
output_image() {
    # Convert the image id to the corresponding unicode symbol.
    local IMAGE_ID="$(printf "%x" "$1")"
    local IMAGE_SYMBOL="$(printf "\U$IMAGE_ID")"

    echostatus "Successfully received imaged id: $IMAGE_ID ($1)"
    echostatus

    # Clear the output file
    if [[ -z "$APPEND" ]]; then
        > "$OUT"
    fi

    # Fill the output with characters representing the image
    for Y in `seq 0 $(expr $ROWS - 1)`; do
        # Each line starts with the escape sequence to set the foreground color
        # to the row number.
        if [[ -z "$NOESC" ]]; then
            echo -en "\e[38;5;${Y}m" >> "$OUT"
        fi
        # And then we just repeat the unicode symbol.
        for X in `seq 0 $(expr $COLS - 1)`; do
            echo -en "$IMAGE_SYMBOL" >> "$OUT"
        done
        printf "\n" >> "$OUT"
    done

    # Reset the style. This is useful when stdout is the same as $OUT to prevent
    # colors used for image display leaking to the subsequent text.
    echo -en "\e[0m"

    return 0
}

#####################################################################
# Try to query the image client id by md5sum
#####################################################################

echostatus "Trying to find image by md5sum"

# Compute image IMGUID based on its md5sum and the number of rows and columns.
IMGUID="$(md5sum "$FILE" | cut -f 1 -d " ")x${ROWS}x${COLS}"
# Pad it with '='' so it looks like a base64 encoding of something (we could
# actually encode the md5sum but I'm too lazy, and the terminal doesn't care
# whatever UIDs we assign to images).
UID_LEN="${#IMGUID}"
PAD_LEN="$((4 - ($UID_LEN % 4)))"
for i in $(seq $PAD_LEN); do
    IMGUID="${IMGUID}="
done

# a=U    the action is to query the image by IMGUID
# q=1    be quiet
gr_command "a=U,q=1;${IMGUID}"

get_terminal_response

# Parse the image client ID in the response.
IMAGE_ID="$(sed -n "s/^.*_G.*i=\([0-9]\+\).*;OK.*$/\1/p" <<< "$TERM_RESPONSE")"

if ! [[ "$IMAGE_ID" =~ ^[0-9]+$ ]]; then
    # If there is no image id in the response then the response should contain
    # something like NOTFOUND
    NOT_FOUND="$(sed -n "s/^.*_G.*;.*NOT.*FOUND.*$/NOTFOUND/p" <<< "$TERM_RESPONSE")"
    if [[ -z "$NOT_FOUND" ]]; then
        # Otherwise the terminal behaves in an unexpected way, better quit.
        invalid_terminal_response
        exit 1
    fi
else
    output_image "$IMAGE_ID"
    exit 0
fi

#####################################################################
# Chunk and upload the image
#####################################################################

# Check if the image is a png, and if it's not, try to convert it.
if ! (file "$FILE" | grep -q "PNG image"); then
    echostatus "Converting $FILE to png"
    if ! convert "$FILE" "$TMPDIR/image.png" || ! [[ -f "$TMPDIR/image.png" ]]; then
        echoerr "Cannot convert image to png"
        exit 1
    fi
    FILE="$TMPDIR/image.png"
fi

# Use some random number for the I id, not to be confused with the client id
# of the image which is not known yet.
ID=$RANDOM

# base64-encode the file and split it into chunks.
echolog "base64-encoding and chunking the image"
cat "$FILE" | base64 -w0 | split -b 4096 - "$TMPDIR/chunk_"

# Issue a command indicating that we want to start data transmission for a new
# image.
# a=t    the action is to transmit data
# I=$ID
# f=100  PNG
# t=d    transmit data directly
# c=,r=  width and height in cells
# s=,v=  width and height in pixels (not used)
# o=z    use compression (not used)
# m=1    multi-chunked data
gr_command "a=t,I=$ID,f=100,t=d,c=${COLS},r=${ROWS},m=1"

CHUNKS_COUNT="$(ls -1 $TMPDIR/chunk_* | wc -l)"
CHUNK_I=0
STARTTIME="$(date +%s%3N)"
SPEED=""

# Transmit chunks and display progress.
for CHUNK in $TMPDIR/chunk_*; do
    echolog "Uploading chunk $CHUNK"
    CHUNK_I=$((CHUNK_I+1))
    if [[ $((CHUNK_I % 10)) -eq 1 ]]; then
        # Do not compute the speed too often
        if [[ $((CHUNK_I % 100)) -eq 1 ]]; then
            # We use +%s%3N tow show time in nanoseconds
            CURTIME="$(date +%s%3N)"
            TIMEDIFF="$((CURTIME - STARTTIME))"
            if [[ "$TIMEDIFF" -ne 0 ]]; then
                SPEED="$(((CHUNK_I*4 - 4)*1000/TIMEDIFF)) K/s"
            fi
        fi
        echostatus "$((CHUNK_I*4))/$((CHUNKS_COUNT*4))K [$SPEED]"
    fi
    # The uploading of the chunk goes here.
    start_gr_command
    echo -en "I=$ID,m=1;"
    cat $CHUNK
    end_gr_command
done

# Tell the terminal that we are done.
gr_command "I=$ID,m=0"

echostatus "Awaiting terminal response"
get_terminal_response

# The terminal should respond with the client id for the image.
IMAGE_ID="$(sed -n "s/^.*_G.*i=\([0-9]\+\),I=${ID}.*;OK.*$/\1/p" <<< "$TERM_RESPONSE")"

if ! [[ "$IMAGE_ID" =~ ^[0-9]+$ ]]; then
    invalid_terminal_response
    exit 1
else
    # Set UID for the uploaded image.
    gr_command "a=U,i=$IMAGE_ID,q=1;${IMGUID}"

    output_image "$IMAGE_ID"
    exit 0
fi
