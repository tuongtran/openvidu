#!/bin/bash

# DEBUG MODE
# If debug mode
DEBUG_MODE=${DEBUG_MODE:-false}
if [[ ${DEBUG_MODE} == true ]]; then
    DEBUG_CHROME_FLAGS="--enable-logging --v=1"
fi
# QUICK_START_ACTION indicates wich action to perform when COMPOSED_QUICK_START mode is executed
# Possible values are:
#   - Without parameters: Just execute all necessary configuration for xfvb and start chrome, waiting forever with a session openned
#   - --start-recording: Executes ffmpeg to record a session but don't stop chrome
#   - --process-recording: Process ffmpeg video and generates a metadata
export COMPOSED_QUICK_START_ACTION=$1

if [[ -z "${COMPOSED_QUICK_START_ACTION}" ]]; then
    { 
        ### Variables ###
        export RESOLUTION=${RESOLUTION:-1920x1080}
        export URL=${URL:-https://www.youtube.com/watch?v=JMuzlEQz3uo}
        export VIDEO_ID=${VIDEO_ID:-video}
        export WIDTH="$(cut -d'x' -f1 <<< $RESOLUTION)"
        export HEIGHT="$(cut -d'x' -f2 <<< $RESOLUTION)"
        export RECORDING_MODE=${RECORDING_MODE}
        
        ### Get a free display identificator ###

        DISPLAY_NUM=99
        DONE="no"
        
        echo "====== Loaded Environment Variables - Start Chrome ======"
        env
        echo "========================================================="

        while [ "$DONE" == "no" ]
        do
        out=$(xdpyinfo -display :$DISPLAY_NUM 2>&1)
        if [[ "$out" == name* ]] || [[ "$out" == Invalid* ]]
        then
            # Command succeeded; or failed with access error;  display exists
            (( DISPLAY_NUM+=1 ))
        else
            # Display doesn't exist
            DONE="yes"
        fi
        done
        
        export DISPLAY_NUM
        echo "First available display -> :$DISPLAY_NUM"
        echo "----------------------------------------"

        pulseaudio -D

        ### Start Chrome in headless mode with xvfb, using the display num previously obtained ###

        touch xvfb.log
        chmod 777 xvfb.log
        xvfb-run --server-num=${DISPLAY_NUM} --server-args="-ac -screen 0 ${RESOLUTION}x24 -noreset" google-chrome --kiosk --start-maximized --test-type --no-sandbox --disable-infobars --disable-gpu --disable-popup-blocking --window-size=$WIDTH,$HEIGHT --window-position=0,0 --no-first-run --ignore-certificate-errors --autoplay-policy=no-user-gesture-required --enable-logging --v=1 $DEBUG_CHROME_FLAGS $URL &> xvfb.log &
        chmod 777 /recordings
    
        # Save Global Environment variables
        echo "export DISPLAY_NUM=$DISPLAY_NUM" > /tmp/display_num

    } 2>&1 | tee -a /tmp/container-start.log
    zzz
    sleep infinity

elif [[ "${COMPOSED_QUICK_START_ACTION}" == "--start-recording" ]]; then
    {
        export $(cat /tmp/display_num | xargs)
        rm -f /tmp/global_environment_vars
        
        # Remove possible stop file from previous recordings
        [ -e stop ] && rm stop
        # Create stop file
        touch stop

        # Variables
        export RESOLUTION=${RESOLUTION:-1920x1080}
        export WIDTH="$(cut -d'x' -f1 <<< $RESOLUTION)"
        export HEIGHT="$(cut -d'x' -f2 <<< $RESOLUTION)"
        export ONLY_VIDEO=${ONLY_VIDEO:-false}
        export FRAMERATE=${FRAMERATE:-25}
        export VIDEO_ID=${VIDEO_ID:-video}
        export VIDEO_NAME=${VIDEO_NAME:-video}
        export VIDEO_FORMAT=${VIDEO_FORMAT:-mp4}
        export RECORDING_JSON="${RECORDING_JSON}"
        
        echo "==== Loaded Environment Variables - Start Recording ====="
        env
        echo "========================================================="
        
        ### Store Recording json data ###

        mkdir /recordings/$VIDEO_ID
        echo $RECORDING_JSON > /recordings/$VIDEO_ID/.recording.$VIDEO_ID
        chmod 777 -R /recordings/$VIDEO_ID
        
        # Save Global Environment variables
        env > /tmp/global_environment_vars
        
        ### Start recording with ffmpeg ###

        if [[ "$ONLY_VIDEO" == true ]]
        then
            # Do not record audio
            <./stop ffmpeg -y -f x11grab -draw_mouse 0 -framerate $FRAMERATE -video_size $RESOLUTION -i :$DISPLAY_NUM -c:v libx264 -preset ultrafast -crf 28 -refs 4 -qmin 4 -pix_fmt yuv420p -filter:v fps=$FRAMERATE "/recordings/$VIDEO_ID/$VIDEO_NAME.$VIDEO_FORMAT"
        else
            # Record audio  ("-f alsa -i pulse [...] -c:a aac")
            <./stop ffmpeg -y -f alsa -i pulse -f x11grab -draw_mouse 0 -framerate $FRAMERATE -video_size $RESOLUTION -i :$DISPLAY_NUM -c:a aac -c:v libx264 -preset ultrafast -crf 28 -refs 4 -qmin 4 -pix_fmt yuv420p -filter:v fps=$FRAMERATE "/recordings/$VIDEO_ID/$VIDEO_NAME.$VIDEO_FORMAT"
        fi
        
    } 2>&1 | tee -a /tmp/container-start-recording.log

elif [[ "${COMPOSED_QUICK_START_ACTION}" == "--stop-recording" ]]; then

    {
        # Load global variables saved before
        export $(cat /tmp/global_environment_vars | xargs)
        
        if [[ -f /recordings/$VIDEO_ID/$VIDEO_ID.jpg ]]; then
            echo "Video already recorded"
            exit 0
        fi
            
        # Stop and wait ffmpeg process to be stopped
        FFMPEG_PID=$(pgrep ffmpeg)
        echo 'q' > stop && tail --pid=$FFMPEG_PID -f /dev/null
        
        
        ### Generate video report file ###
        ffprobe -v quiet -print_format json -show_format -show_streams /recordings/$VIDEO_ID/$VIDEO_NAME.$VIDEO_FORMAT > /recordings/$VIDEO_ID/$VIDEO_ID.info    
        
        ### Change permissions to all generated files ###
        sudo chmod -R 777 /recordings/$VIDEO_ID
        
        ### Update Recording json data ###
        TMP=$(mktemp /recordings/$VIDEO_ID/.$VIDEO_ID.XXXXXXXXXXXXXXXXXXXXXXX.json)
        INFO=$(cat /recordings/$VIDEO_ID/$VIDEO_ID.info | jq '.')
        HAS_AUDIO_AUX=$(echo $INFO | jq '.streams[] | select(.codec_type == "audio")')
        if [ -z "$HAS_AUDIO_AUX" ]; then HAS_AUDIO=false; else HAS_AUDIO=true; fi
        HAS_VIDEO_AUX=$(echo $INFO | jq '.streams[] | select(.codec_type == "video")')
        if [ -z "$HAS_VIDEO_AUX" ]; then HAS_VIDEO=false; else HAS_VIDEO=true; fi
        SIZE=$(echo $INFO | jq '.format.size | tonumber')
        DURATION=$(echo $INFO | jq '.format.duration | tonumber')

        if [[ "$HAS_AUDIO" == false && "$HAS_VIDEO" == false ]]
        then
            STATUS="failed"
        else
            STATUS="stopped"
        fi

        jq -c -r ".hasAudio=$HAS_AUDIO | .hasVideo=$HAS_VIDEO | .duration=$DURATION | .size=$SIZE | .status=\"$STATUS\"" "/recordings/$VIDEO_ID/.recording.$VIDEO_ID" > $TMP && mv $TMP /recordings/$VIDEO_ID/.recording.$VIDEO_ID
        rm -f $TMP
        
        ### Change permissions to metadata file ###
        sudo chmod 777 /recordings/$VIDEO_ID/.recording.$VIDEO_ID
        
        ### Generate video thumbnail ###

        MIDDLE_TIME=$(ffmpeg -i /recordings/$VIDEO_ID/$VIDEO_NAME.$VIDEO_FORMAT 2>&1 | grep Duration | awk '{print $2}' | tr -d , | awk -F ':' '{print ($3+$2*60+$1*3600)/2}')
        THUMBNAIL_HEIGHT=$((480*$HEIGHT/$WIDTH))
        ffmpeg -ss $MIDDLE_TIME -i /recordings/$VIDEO_ID/$VIDEO_NAME.$VIDEO_FORMAT -vframes 1 -s 480x$THUMBNAIL_HEIGHT /recordings/$VIDEO_ID/$VIDEO_ID.jpg &> /tmp/ffmpeg-thumbnail.log
        
        echo "Recording finished /recordings/$VIDEO_ID/$VIDEO_NAME.$VIDEO_FORMAT"
        
    } 2>&1 | tee -a /tmp/container-stop-recording.log
fi

if [[ ${DEBUG_MODE} == "true" && ! -z $VIDEO_ID ]]; then
    export $(cat /tmp/display_num | xargs)
    [[ -f /tmp/container-start.log ]] && cp /tmp/container-start.log /recordings/$VIDEO_ID/$VIDEO_ID-container-start.log || echo "/tmp/container-start.log not found"
    [[ -f /tmp/container-start-recording.log ]] && cp /tmp/container-start-recording.log /recordings/$VIDEO_ID/$VIDEO_ID-container-start-recording.log || echo "/tmp/container-start-recording.log not found"
    [[ -f /tmp/container-stop-recording.log ]] && cp /tmp/container-stop-recording.log /recordings/$VIDEO_ID/$VIDEO_ID-container-stop-recording.log || echo "/tmp/container-stop-recording.log not found"
    [[ -f ~/.config/google-chrome/chrome_debug.log ]] && cp ~/.config/google-chrome/chrome_debug.log /recordings/$VIDEO_ID/chrome_debug.log || echo "~/.config/google-chrome/chrome_debug.log"
fi

### Change permissions to all generated files ###
sudo chmod -R 777 /recordings/$VIDEO_ID




