//
//  ViewController.m
//  VTDecode
//
//  Created by LiDinggui on 2018/5/15.
//  Copyright © 2018年 MKTECH. All rights reserved.
//

#import "ViewController.h"

#import <VideoToolbox/VideoToolbox.h>

@interface ViewController ()

@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) CADisplayLink *displayLink;

@end

const uint8_t StartCode[4] = {0, 0, 0, 1};

@implementation ViewController
{
    dispatch_queue_t _decodeQueue;
    VTDecompressionSessionRef _decodeSession;
    CMFormatDescriptionRef _formatDescription;
    uint8_t *_sps;
    long _spsSize;
    uint8_t *_pps;
    long _ppsSize;
    
    NSInputStream *_inputStream;
    uint8_t *_packetBuffer;
    long _packetSize;
    uint8_t *_inputBuffer;
    long _inputSize;
    long _inputMaxSize;
}

- (void)dealloc
{
    [self endVideoToolBox];
    
    if (_packetBuffer)
    {
        free(_packetBuffer);
        _packetBuffer = NULL;
    }
    if (_inputBuffer)
    {
        free(_inputBuffer);
        _inputBuffer = NULL;
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    _decodeQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    
    CGFloat buttonWidth = 100.0;
    CGFloat buttonHeight = 44.0;
    CGFloat statusBarHeight = UIApplication.sharedApplication.statusBarFrame.size.height;
    
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake((self.view.bounds.size.width - buttonWidth) / 2.0, statusBarHeight + 8.0, buttonWidth, buttonHeight);
    button.backgroundColor = [UIColor clearColor];
    [button setTitle:@"Play" forState:UIControlStateNormal];
    [button setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    [button addTarget:self action:@selector(buttonClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    self.button = button;
    
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateFrame)];
    displayLink.frameInterval = 2; // 默认是30FPS的帧率录制
    [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    displayLink.paused = YES;
    self.displayLink = displayLink;
}

- (void)buttonClicked:(UIButton *)button
{
    button.hidden = YES;
    [self startDecode];
}

- (void)updateFrame
{
    if (_inputStream)
    {
        dispatch_sync(_decodeQueue, ^{
            [self readPacket];
            if (self->_packetBuffer == NULL || self->_packetSize == 0)
            {
                [self onInputEnd];
                return;
            }
            uint32_t nalSize = (uint32_t)(self->_packetSize - 4);
            uint32_t *pNalSize = (uint32_t *)(self->_packetBuffer);
            *pNalSize = CFSwapInt32HostToBig(nalSize);
            
            CVPixelBufferRef pixelBuffer = NULL;
            int nalType = self->_packetBuffer[4] & 0x1F;
            switch (nalType)
            {
                case 0x05:
                {
                    // IDR frame
                    [self initVideoToolBox];
                    pixelBuffer = [self decode];
                }
                    break;
                case 0x07:
                {
                    // SPS
                    self->_spsSize = self->_packetSize - 4;
                    self->_sps = malloc(self->_spsSize);
                    memcpy(self->_sps, self->_packetBuffer + 4, self->_spsSize);
                }
                    break;
                case 0x08:
                {
                    // PPS
                    self->_ppsSize = self->_packetSize - 4;
                    self->_pps = malloc(self->_ppsSize);
                    memcpy(self->_pps, self->_packetBuffer + 4, self->_ppsSize);
                }
                    break;
                    
                default:
                {
                    // B/P frame
                    pixelBuffer = [self decode];
                }
                    break;
            }
            
            if (pixelBuffer)
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    // display pixelBuffer
                    CVPixelBufferRelease(pixelBuffer);
                });
            }
        });
    }
}

- (void)startDecode
{
    [self onInputStart];
    self.displayLink.paused = NO;
}

- (void)onInputStart
{
    _inputStream = [[NSInputStream alloc] initWithFileAtPath:[[NSBundle mainBundle] pathForResource:@"abc" ofType:@"h264"]];
    [_inputStream open];
    _inputSize = 0;
    _inputMaxSize = 640 * 480 * 3 * 4;
    _inputBuffer = malloc(_inputMaxSize);
}

- (void)onInputEnd
{
    [_inputStream close];
    _inputStream = nil;
    if (_inputBuffer)
    {
        free(_inputBuffer);
        _inputBuffer = NULL;
    }
    
    self.displayLink.paused = YES;
    self.button.hidden = NO;
}

- (void)readPacket
{
    if (_packetSize)
    {
        _packetSize = 0;
    }
    if (_packetBuffer)
    {
        free(_packetBuffer);
        _packetBuffer = NULL;
    }
    if (_inputSize < _inputMaxSize && _inputStream.hasBytesAvailable)
    {
        _inputSize += [_inputStream read:_inputBuffer + _inputSize maxLength:_inputMaxSize - _inputSize];
    }
    if (memcmp(_inputBuffer, StartCode, 4) == 0)
    {
        if (_inputSize > 4) // 除了开始码还有内容
        {
            uint8_t *start = _inputBuffer + 4;
            uint8_t *end = _inputBuffer + _inputSize;
            while (start != end)
            {
                if (memcmp(start - 3, StartCode, 4) == 0)
                {
                    _packetSize = start - _inputBuffer - 3;
                    if (_packetBuffer)
                    {
                        free(_packetBuffer);
                        _packetBuffer = NULL;
                    }
                    _packetBuffer = malloc(_packetSize);
                    memcpy(_packetBuffer, _inputBuffer, _packetSize);
                    memmove(_inputBuffer, _inputBuffer + _packetSize, _inputSize - _packetSize); // 把缓冲区前移
                    _inputSize -= _packetSize;
                    break;
                }
                else
                {
                    ++start;
                }
            }
        }
    }
}

void didDecompress(void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef pixelBuffer, CMTime presentationTimeStamp, CMTime presentationDuration )
{
    CVPixelBufferRef *outputPixelBuffer = (CVPixelBufferRef *)sourceFrameRefCon;
    *outputPixelBuffer = CVPixelBufferRetain(pixelBuffer);
}

- (void)initVideoToolBox
{
    if (!_decodeSession)
    {
        const uint8_t *parameterSetPointers[2] = {_sps, _pps};
        const size_t parameterSetSizes[2] = {_spsSize, _ppsSize};
        OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, parameterSetPointers, parameterSetSizes, 4, &_formatDescription);
        if (status == noErr)
        {
            CFDictionaryRef attrs = NULL;
            const void *keys[] = {kCVPixelBufferPixelFormatTypeKey};
            //      kCVPixelFormatType_420YpCbCr8Planar is YUV420
            //      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange is NV12
            uint32_t value = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
            const void *values[] = {CFNumberCreate(NULL, kCFNumberSInt32Type, &value)};
            attrs = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);
            
            VTDecompressionOutputCallbackRecord callbackRecord;
            callbackRecord.decompressionOutputCallback = didDecompress;
            callbackRecord.decompressionOutputRefCon = NULL;
            
            status = VTDecompressionSessionCreate(kCFAllocatorDefault, _formatDescription, NULL, attrs, &callbackRecord, &_decodeSession);
            
            CFRelease(attrs);
        }
    }
}

- (void)endVideoToolBox
{
    if (_decodeSession)
    {
        VTDecompressionSessionInvalidate(_decodeSession);
        CFRelease(_decodeSession);
        _decodeSession = NULL;
    }
    if (_formatDescription)
    {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
    if (_sps)
    {
        free(_sps);
        _sps = NULL;
    }
    if (_pps)
    {
        free(_pps);
        _pps = NULL;
    }
    _spsSize = _ppsSize = 0;
}

- (CVPixelBufferRef)decode
{
    CVPixelBufferRef outputPixelBuffer = NULL;
    if (_decodeSession)
    {
        CMBlockBufferRef blockBuffer = NULL;
        OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, (void *)_packetBuffer, _packetSize, kCFAllocatorNull, NULL, 0, _packetSize, 0, &blockBuffer);
        if (status == kCMBlockBufferNoErr && blockBuffer)
        {
            CMSampleBufferRef sampleBuffer = NULL;
            const size_t sampleSizeArray[] = {_packetSize};
            status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuffer, _formatDescription, 1, 0, NULL, 1, sampleSizeArray, &sampleBuffer);
            if (status == kCMBlockBufferNoErr && sampleBuffer)
            {
                VTDecodeFrameFlags decodeFrameFlags = 0;
                VTDecodeInfoFlags decodeInfoFlags = 0;
                // 默认是同步操作
                // 调用didDecompress,返回后再回调
                OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(_decodeSession, sampleBuffer, decodeFrameFlags, &outputPixelBuffer, &decodeInfoFlags);
                CFRelease(sampleBuffer);
            }
            CFRelease(blockBuffer);
        }
    }
    return outputPixelBuffer;
}

@end
