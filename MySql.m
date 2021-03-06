// MySqueakQl - MySql.m
//
// Copyright (C) 2012 Ciaran Jessup
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
//  Created by Ciaran on 01/02/2012.
//
#import "MySql.h"

@implementation MySql
@synthesize protocolImpl;

-(id) initWithProtocol:(MySqlProtocol*) __attribute__((ns_consumed)) protocol user:(NSString *)user password:(NSString *)password {
    if ( self = [super init] ) {
        protocolImpl= protocol;
        if( [protocolImpl connect] ) {
            if( ![protocolImpl handshakeForUserName:user
                                          password:password] ) {
                return NULL;
            }
        }
        else {
            return NULL;
        }
    }
    
    return self;
}

-(id) initWithHost:(NSString *)host port:(UInt16)port user:(NSString *)user password:(NSString *)password {
    return [self initWithProtocol:[[MySqlProtocol alloc]initWithHost:host port:port]
                             user:user
                         password:password];
}

-(void)dealloc {
    if( protocolImpl != NULL ) {
        [protocolImpl release];
    }
    [super dealloc];
}

-(int) selectDatabase:(NSString*)database {
    volatile __block bool blockCalled= false;
    volatile __block int selectDBResult= 0;
    
    NSData* data=[database dataUsingEncoding:NSUTF8StringEncoding];
    [protocolImpl sendCommand:2 data:data continueWithBlock:^(int result){
            if( result ) {
                NSData* okOrErrorPacket= [protocolImpl readPacket];
                if( okOrErrorPacket ) {
                    UInt8* resultPacketData= (UInt8*)[okOrErrorPacket bytes];
                    if( resultPacketData[0] == 0xFF ) {
                        uint16_t errorNumber= resultPacketData[1] + (resultPacketData[2]<<8);
                        // sqlstate is chars 3-> 8
                        
                        NSString* errorMessage= [[NSString alloc] initWithCString: (const char*)(resultPacketData+9) encoding:NSASCIIStringEncoding];
                        
                        NSLog(@"ERROR: %@ (%u)", errorMessage, errorNumber);
                        for(int i=0;i< [okOrErrorPacket length]; i++ ) {
                            fprintf(stderr, "%x ", resultPacketData[i]);
                        }
                        [errorMessage release];

                        selectDBResult= -1;
                    }
                    else {
                        selectDBResult= 1;
                    }
                    [okOrErrorPacket release];
                }
            } else {
                selectDBResult= result;
            }
            blockCalled= true;
    }];
    // As an attempt to simplify the external API, we
    // simulate a blocking API by blocking the calling thread, until
    // the command's callback block has executed.
    while(!blockCalled) {
        [NSThread sleepForTimeInterval:0.25];
    }
    return selectDBResult;
}

-(void) performQuery:(NSString*)query continueWithBlock:(void (^)(MySqlResults* results))block {
    NSData* data=[query dataUsingEncoding:NSUTF8StringEncoding];
    [protocolImpl sendCommand:3  data:data continueWithBlock:^(int result){
                NSData* initialServerResponsePacket= [protocolImpl readPacket];
                UInt8* resultPacketData= (UInt8*)[initialServerResponsePacket bytes];
                MySqlResults* results= [[MySqlResults alloc] init];
                if( *resultPacketData == 0xFF ) {
                    uint16_t errorNumber= resultPacketData[1] + (resultPacketData[2]<<8);
                    // sqlstate is chars 3-> 8
                    
                    NSString* errorMessage= [NSString stringWithCString: (const char*)(resultPacketData+9) encoding:NSASCIIStringEncoding];
                    //TODO: this is confusing as it will display older packet's data as it doesn't check the termination boundary
                    //of the string..dumb...
                    NSLog(@"ERROR: %@ (%u)", errorMessage, errorNumber);
                }
                else {
                    if( *resultPacketData == 0x00 ) {
                        // OK Packet
                        resultPacketData++;
                        results.affectedRows= [protocolImpl readLengthCodedLength:&resultPacketData];
                        results.insertId= [protocolImpl readLengthCodedLength:&resultPacketData];
                        //UInt16 serverStatus= *resultPacketData + ((*(resultPacketData+1))<<8);
                        resultPacketData+=2;
                        //UInt16 warningCount= *resultPacketData + ((*(resultPacketData+1))<<8);
                        resultPacketData+=2;
                        // Meh ignore the message (remaining part of packet)
                    }
                    else {
                        // Result Set Packet
                        UInt8 fieldCount= *((unsigned char*)[initialServerResponsePacket bytes]);
                        NSMutableArray* fields= [NSMutableArray arrayWithCapacity:10];
                        results.fields=fields;
                        results.affectedRows= [NSNumber numberWithUnsignedInt:0];
                        NSLog(@"Found %d fields...",fieldCount);
                        NSData* fieldDescriptor= [protocolImpl readPacket];
                        UInt8* byteData;
                        
                        while( ![protocolImpl isEOFPacket: fieldDescriptor ] ) {
                            byteData= (UInt8*)[fieldDescriptor bytes];
                            NSMutableDictionary* field= [NSMutableDictionary dictionary];
                            NSString* value= [protocolImpl readLengthCodedString:&byteData];
                            [field setValue: value forKey:@"catalog"];
                            [value release];
                            value= [protocolImpl readLengthCodedString:&byteData];
                            [field setValue:value forKey:@"db"];
                            [value release];
                            value= [protocolImpl readLengthCodedString:&byteData];
                            [field setValue:value forKey:@"table"];
                            [value release];
                            value= [protocolImpl readLengthCodedString:&byteData];
                            [field setValue:value forKey:@"org_table"];
                            [value release];
                            value= [protocolImpl readLengthCodedString:&byteData];
                            [field setValue:value forKey:@"name"];
                            [value release];
                            value= [protocolImpl readLengthCodedString:&byteData];
                            [field setValue:value forKey:@"org_name"];
                            [value release];


                            [fields addObject: field];
                            [fieldDescriptor release];
                            fieldDescriptor= [protocolImpl readPacket];
                        }
                        [fieldDescriptor release];

                        NSMutableArray* arr= [NSMutableArray arrayWithCapacity:10];
                        results.rows=arr;

                        NSData* rowDataPacket= [protocolImpl readPacket];
                        while( ![protocolImpl isEOFPacket: rowDataPacket ] ) {
                            byteData= (UInt8*)[rowDataPacket bytes];
                            NSMutableDictionary* record= [NSMutableDictionary dictionary];
                            for(int i=0;i< fieldCount;i++) {
                                NSString* value= [protocolImpl readLengthCodedString:&byteData];
                                [record setValue:value forKey:[ [fields objectAtIndex:i] valueForKey:@"name"]];
                                [value release];
                            }
                            [arr addObject: record];
                            [rowDataPacket release];
                            rowDataPacket= [protocolImpl readPacket];
                        }
                        [rowDataPacket release];
                    }
                }
                [initialServerResponsePacket release]; // We release this on the happy path when we release 'resultSetHeaderPacket'
                block( results );
                [results release];
            }];
}

-(int) quit {
    volatile __block bool blockCalled= false;
    volatile __block int quitResult= 0;
    [protocolImpl sendCommand:1 data:NULL continueWithBlock:^(int result){
        blockCalled= true;
        quitResult= result;
    }];

    // As an attempt to simplify the external API, we
    // simulate a blocking API by blocking the calling thread, until
    // the command's callback block has executed.
    while(!blockCalled) {
        [NSThread sleepForTimeInterval:0.25];
    }
    [protocolImpl dealloc];
    protocolImpl= NULL;
    return quitResult;
}

@end
