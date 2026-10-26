`map_gametime_to_videotime` function in @time_mapper_lib c++ library takes two arguments

- path to a video file
- sub region information

In the function, using FFMPEG, sample every 0.5 seconds of the video, crop the sub region of the frame, and send it to the @ocr python library.

In the python library, use pp-ocrv6 to extract the texts.

THe video is going to be some basketball broadcasting, and the subsection will be the section of the video where it shows the game time. Extract the game time from the image, and return to the c++. The game time format will be one of these two

- mm:ss (minutes and seconds like 17:23 or 1:04)
- :ss.s (seconds including fractional parts like :17.3 or :06.1)

In C++, collect all the information and ultimately create a mapping from the game time to the video time. Some game time seconds could be longer than one video time second because the game could have been paused due to fouls or some intervention, therefore the mapping should be from a game time second to a video time range. Also, some frames might not have any text at that region due to maybe advertisement or breaktime or highlight replay.

Don't do anything with the mapping information yet. I'm not decided what to do with it.

Create unit test for the c++ with the test video files at @time_mapper_lib/test-data/ .


