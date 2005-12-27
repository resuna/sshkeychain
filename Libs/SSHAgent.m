#import "SSHAgent.h"

#import "SSHKeychain.h"
#import "SSHTool.h"
#import "PreferenceController.h"

#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>

#define BUFSIZE 4096

SSHAgent *currentAgent;

/* This function resides in Controller.m. */
extern NSString *local(NSString *theString);

@implementation SSHAgent

/* Return the current agent, if set. */
+ (id)currentAgent
{
	if(currentAgent == nil)
	{
		currentAgent = [[SSHAgent alloc] init];
	}
	
	return currentAgent;
}

- (id)init
{
	if((self = [super init]) == nil)
	{
		return nil;
	}

	currentAgent = self;

        [[NSNotificationCenter defaultCenter] addObserver:self
                selector:@selector(keysOnAgentStatusChange:) name:@"AgentFilled" object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                selector:@selector(keysOnAgentStatusChange:) name:@"AgentEmptied" object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                selector:@selector(keysOnAgentStatusChange:) name:@"KeysOnAgentUnknown" object:nil];
	
	socketPathLock = [[NSLock alloc] init];
	agentSocketPathLock = [[NSLock alloc] init];
	keysOnAgentLock = [[NSLock alloc] init];
	openPanelLock = [[NSLock alloc] init];
	thePidLock = [[NSLock alloc] init];
	
	return self;
}

- (void)dealloc
{
	currentAgent = nil;

	[socketPathLock dealloc];
	[agentSocketPathLock dealloc];
	[keysOnAgentLock dealloc];
	[openPanelLock dealloc];
	[thePidLock dealloc];

	[super dealloc];
}

/* Set the socket location for us to bind to. */
- (BOOL)setSocketPath:(NSString *)path
{
	if([self isRunning] == YES)
	{
		NSLog(@"setSocketPath: can't change path while the agent is running.");
		return NO;
	}

	[socketPathLock lock];

	/* We don't use the socketPath method here, since we've just locked socketPathLock. */
	if(socketPath != nil)
	{
		[socketPath release];
		socketPath = nil;
	}

	socketPath = [[NSString stringWithString:path] retain];
	[socketPathLock unlock];
	
	return YES;
}

/* Get the socket path we bind to. */
- (NSString *)socketPath
{
	NSString *returnString = nil;
	
	[socketPathLock lock];
	
	if(socketPath)
	{
		returnString = [NSString stringWithString:socketPath];
	}
	
	[socketPathLock unlock];

	return returnString;
}

/* Get the socket path the ssh-agent listens to. */
- (NSString *)agentSocketPath
{
	NSString *returnString = nil;

	[agentSocketPathLock lock];
	
	if(agentSocketPath)
	{
		returnString = [NSString stringWithString:agentSocketPath];
	}
	
	[agentSocketPathLock unlock];

	return returnString;
}

/* Start the agent. */
- (BOOL)start
{
	NSString *theOutput;
	SSHTool *theTool;
	NSArray *lines, *columns;
	int i;

	/* If the PID is > 0, the agent should (in theory) be running. */
	if([self pid] > 0)
	{
		NSLog(@"Agent is already started");
		return NO;
	}

	/* Clear the agentSocketPath object. */
	if([self agentSocketPath]) 
	{
		[agentSocketPathLock lock];
		[agentSocketPath release];
		agentSocketPath = nil;
		[agentSocketPathLock unlock];
	}


	if([self socketPath] == nil)
	{
		NSLog(@"DEBUG: start: socketPath not set");
		return NO;
	}

	/* Initialize a ssh-agent SSHTool, set the arguments to -c for c-shell output. */
	theTool = [SSHTool toolWithName:@"ssh-agent"];
	[theTool setArgument:@"-c"];

	/* Launch the agent and retrieve stdout. */
	theOutput = [theTool launchForStandardOutput];

	if(theOutput == nil)
	{
		NSLog(@"ssh-agent didn't launch");
		return NO;
	}

	/* Split the lines with delimiter ";\n". */
	lines = [theOutput componentsSeparatedByString:@";\n"];

	for(i=0; i < [lines count]; i++)
	{
		/* Split the line with delimiter " ". */
		columns = [[lines objectAtIndex:i] componentsSeparatedByString:@" "];

		/* If 2nd column matches "SSH_AUTH_SOCK", then 3rd column is the socket path. */
		if(([columns count] == 3) && (strcmp([[columns objectAtIndex:1] cString], "SSH_AUTH_SOCK") == 0))
		{
			[agentSocketPathLock lock];
			agentSocketPath = [[NSString stringWithString:[columns objectAtIndex:2]] retain];
			[agentSocketPathLock unlock];
		}

		/* If 2nd column matches "SSH_AGENT_PID", then 3rd column is the PID. */
		if(([columns count] == 3) && (strcmp([[columns objectAtIndex:1] cString], "SSH_AGENT_PID") == 0))
		{
			[thePidLock lock];
			thePid = [[columns objectAtIndex:2] intValue];
			[thePidLock unlock];
		}
	}

	/* If the PID is > 0 but the socket path isn't filled, stop the agent and return -1. */
	if(([self pid] > 0) && (([self agentSocketPath] == nil) || ([agentSocketPath length] < 1)))
	{
		NSLog(@"SSHAgent start: ssh-agent didn't give the output we expected");
		[self stop];
		return NO;
	}

	/* If there's no PID just return -1. */
	if([self pid] < 1)
	{
		NSLog(@"SSHAgent start: ssh-agent didn't give the output we expected");
		return NO;
	}

	/* Handle connections in a seperate thread. */
	[NSThread detachNewThreadSelector:@selector(handleAgentConnections) toTarget:self withObject:nil];

	/* Check if agent is alive in a seperate thread. */
	[NSThread detachNewThreadSelector:@selector(checkAgent) toTarget:self withObject:nil];

	[[NSNotificationCenter defaultCenter]  postNotificationName:@"AgentStarted" object:nil];

	return YES;
}

/* Stop the agent. */
- (BOOL)stop
{
	/* We can't stop something if we haven't got the pid. */
	if([self pid] > 0)
	{
		/* We don't need to check if this fails. We clean up the variables either way. */
		kill([self pid], SIGTERM);

		[agentSocketPathLock lock];
		[agentSocketPath release];
		agentSocketPath = nil;
		[agentSocketPathLock unlock];

		[self closeSockets];

		[thePidLock lock];
		thePid = 0;
		[thePidLock unlock];

		[keysOnAgentLock lock];
		[keysOnAgent release];
		keysOnAgent = nil;
		[keysOnAgentLock unlock];

		[[NSNotificationCenter defaultCenter]  postNotificationName:@"AgentStopped" object:nil];
	}

	return YES;
}

/* Return YES if the agent is (in theory) running, and NO if not. */
- (BOOL)isRunning
{
	if([self pid] > 0) { return YES; }
	else { return NO; }
}

/* Get the pid. */
- (int)pid
{
	int returnInt;

	[thePidLock lock];
	returnInt = thePid;
	[thePidLock unlock];

	return returnInt;
}

/* Return the keys on agent since last notification. */
- (NSArray *)keysOnAgent
{
	NSArray *returnArray = nil;

	[keysOnAgentLock lock];
	
	if(keysOnAgent)
	{
		returnArray = [NSArray arrayWithArray:keysOnAgent];
	}
	
	[keysOnAgentLock unlock];

	return returnArray;
}

/* Close our sockets. */
- (void)closeSockets
{
	close(s);
	if([[self socketPath] cString] != nil)
	{
		unlink([[socketPath self] cString]);
	}
}

/* Handle connections to our socket. */
- (void)handleAgentConnections
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSArray *array;

	struct sockaddr_un lsa;
	struct sockaddr_un rsa;

	int i, used, allocated, a, hfd, lfd, rfd ,r;
	socklen_t ssa;
	int *fds;
	fd_set rfds;

	char buf[BUFSIZE];
	
	memset(&lsa, 0, sizeof(lsa));
	memset(&rsa, 0, sizeof(rsa));

	/* Fill the sockaddr_un structs. */
	lsa.sun_family = AF_UNIX;
	strncpy(lsa.sun_path, [[self socketPath] cString], sizeof(lsa.sun_path));

	rsa.sun_family = AF_UNIX;
	strncpy(rsa.sun_path, [[self agentSocketPath] cString], sizeof(rsa.sun_path));

	/* Make a socket. */
	if((s = socket(AF_UNIX, SOCK_STREAM, 0)) < 0)
	{
		NSLog(@"handleAgentConnections: socket() failed");
		[self stop];
		[pool release];
		return;
	}

	/* Bind it. */
	if(bind(s, (struct sockaddr *) &lsa, sizeof(lsa)) < 0)
	{
		unlink([[self socketPath] cString]);
		if(bind(s, (struct sockaddr *) &lsa, sizeof(lsa)) < 0)
		{ 
			NSLog(@"DEBUG: handleAgentConnections: bind() failed");
			
			[self stop];
			[pool release];
			return;
		}
	}

	/* Listen to it. */
	if(listen(s, 30) < 0)
	{
		[NSException raise: NSInternalInconsistencyException
			    format: @"listen() failed (%s)", strerror(errno)];
		[self stop];
		[pool release];
		return;
	}
	
	allocated = 10;
	used = 0;

	/* Allocate space for 10 int's, to keep track of fd's in use. */
	fds = malloc(sizeof(int) * allocated);
	if(fds == nil)
	{
		NSLog(@"handleAgentConnections: malloc() failed");
		[self stop];
		[pool release];
		return;
	}

	/* Make the listening socket nonblocking. */
	fcntl(s, F_SETFL, O_NONBLOCK);

	FD_ZERO(&rfds);
	FD_SET(s, &rfds);

	hfd = s;

	ssa = (socklen_t) sizeof(struct sockaddr);

	/* Run a select over all available fd's. */
	while((a = select(hfd + 1, &rfds, (fd_set *) 0, (fd_set *) 0, nil)))
	{
		/* If a == -1 and errno == EBADF, then we're probably exiting. Stop agent to be sure and return. */
		if((a == -1) && (errno == EBADF))
		{
			[self stop];
			free(fds);
			[pool release];
			return;
		}

		/* If a == -1 and errno != EINTR, the shit has probably hit the fan. Exit. */
		if((a == -1) && (errno != EINTR))
		{
			NSLog(@"handleAgentConnections: select() encountered a fatal error");
			[self stop];
			free(fds);
			[pool release];
			return;
		}

		/* If the listening socket is part of the active set, then accept the connection and add it to the list of fd's. */
		if((FD_ISSET(s, &rfds)) && ((lfd = accept(s, (struct sockaddr *) &lsa, &ssa)) > -1))
		{
		
			if(allocated < (used + 2))
			{
				fds = realloc(fds, ((sizeof(int) * allocated) * 2));
				allocated = allocated * 2;
				if(fds == nil)
				{
					NSLog(@"handleAgentConnections: realloc() failed");
					[self stop];
					[pool release];
					return;
				}
			}

			/* Add the accepted socket to the list. */
			fds[used] = lfd;
			used++;

			/* Create a socket. */
			if((rfd = socket(AF_UNIX, SOCK_STREAM, 0)) < 0)
			{
				NSLog(@"handleAgentConnections: Socket creation failed");
				fds[used - 1] = -1;
				used--;
				close(lfd);
				[self stop];
				free(fds);
				[pool release];
				return;
			}

			/* Connect to the ssh-agent. */
			else if(connect(rfd, (struct sockaddr *) &rsa, sizeof(rsa)) < 0)
			{
				NSLog(@"handleAgentConnections: Connecting to ssh-agent failed");
				fds[used - 1] = -1;
				used--;
				close(lfd);
				[self stop];
				free(fds);
				[pool release];
				return;
			}

			/* Add it to the list. */
			else
			{
				fds[used] = rfd;
				used++;
			}
		}

		/* If we got here, the active fd's are part of a pipe between us and the real ssh-agent. */
		else
		{
			/* Check activity of each fd in the list. */
			for(i = 0; i < used; i++)
			{
				if(FD_ISSET(fds[i], &rfds))
				{
					/* If i is even, forward it's traffic to the agent. */
					if(((i & 1) == 0) && (fds[i+1] > 0))
					{
						r = read(fds[i], buf, BUFSIZE);

						/* If r < 1, the connection is closed. Close all fd's of the pipe. */
						if(r < 1)
						{
							close(fds[i]);
							close(fds[i+1]);
							fds[i] = fds[used-2];
							fds[i+1] = fds[used-1];
							used = used - 2;
						}

						else
						{
							/* If read byte is \1 or \11, and there are no keys on the chain, run noKeysForInput:withObject:. */
							if(((r == 1) && ((buf[0] == 11) || (buf[0] == 1))) || ((r == 5) && ((buf[4] == 11) || (buf[4] == 1)))) 
							{
								array = [NSArray arrayWithObjects:[NSNumber numberWithInt:fds[i+1]], 
									[NSString stringWithCString:buf length:r], [NSNumber numberWithInt:r],
									[NSNumber numberWithInt:fds[i]], nil];

								[NSThread detachNewThreadSelector:@selector(inputFromClient:) toTarget:self withObject:array]; 
							}

							/* If read byte is \9 or \19, remove all keys from the agent. (\9 and \19 is a remove_all_keys request) */
							else if((((r == 1) && ((buf[0] == 9) || (buf[0] == 19))) || ((r ==5) && ((buf[4] == 9) || (buf[4] == 19))))
								 && ([[self keysOnAgent] count] > 0))
							{
								[[SSHKeychain currentKeychain] removeKeysFromAgent];
								write(fds[i+1], buf, r);
							}

							/* If the first byte is \8 or \18, a key is removed. */
							else if(((buf[0] == 8) || (buf[0] == 18)) && ([[self keysOnAgent] count] > 0))
							{
								write(fds[i+1], buf, r);

								[keysOnAgentLock lock];
								keysOnAgent = [[[SSHAgent currentAgent] currentKeysOnAgent] retain];
								[keysOnAgentLock unlock];		
								[[NSNotificationCenter defaultCenter]  postNotificationName:@"KeysOnAgentUnknown" object:nil];
							}

							/* If the first byte is \7 or \17, a key is added. */
							else if((buf[0] == 7) || (buf[0] == 17))
							{
								write(fds[i+1], buf, r);

								[keysOnAgentLock lock];
								keysOnAgent = [[[SSHAgent currentAgent] currentKeysOnAgent] retain];
								[keysOnAgentLock unlock];		

								[[NSNotificationCenter defaultCenter]  postNotificationName:@"KeysOnAgentUnknown" object:nil];
							}

							else
							{
								write(fds[i+1], buf, r);
							}
						}
					}

					/* If i is uneven, forward it's traffic to the client. */
					else if((i > 0) && (fds[i-1] > 0))
					{
						r = read(fds[i], buf, BUFSIZE);

						/* If r < 1, the connection is closed. Close all fd's of the pipe. */
						if(r < 1)
						{
							close(fds[i]);
							close(fds[i-1]);
							fds[i] = fds[used-1];
							fds[i-1] = fds[used-2];
							used = used - 2;
						}

						else
						{
							write(fds[i-1], buf, r);
						}
					}
				}
			}
		}
	

		/* Refill the fd_set. */
		FD_ZERO(&rfds);
		FD_SET(s, &rfds);
		hfd = s;
		
		for(i = 0; i < used; i++)
		{
			FD_SET(fds[i], &rfds);
			if(fds[i] > hfd) { hfd = fds[i]; }
		}
	}

	free(fds);
	[pool release];
}

/* When there's a request from a client, this method is called. */
- (void)inputFromClient:(id)object
{
	NSAutoreleasePool *pool;
	SSHKeychain *keychain;
	NSMutableDictionary *dict;

	int fd, len, src;
	const char *buf;

	SInt32 error;
	CFUserNotificationRef notification;
	CFOptionFlags response;

	pool = [[NSAutoreleasePool alloc] init];

	fd = [[object objectAtIndex:0] intValue];
	buf = [[object objectAtIndex:1] cString];
	len = [[object objectAtIndex:2] intValue];
	src = [[object objectAtIndex:3] intValue];

	if([[NSUserDefaults standardUserDefaults] boolForKey:AskForConfirmationString]) 
	{
		/* Dictionary for the panel. */
		dict = [NSMutableDictionary dictionary];
		
		[dict setObject:local(@"ConfirmationPanelTitle") forKey:(NSString *)kCFUserNotificationAlertHeaderKey];
		[dict setObject:local(@"ConfirmationPanelText") forKey:(NSString *)kCFUserNotificationAlertMessageKey];
		
		[dict setObject:[NSURL fileURLWithPath:[[[NSBundle mainBundle] resourcePath]
					stringByAppendingString:@"/SSHKeychain.icns"]] forKey:(NSString *)kCFUserNotificationIconURLKey];
		
		[dict setObject:local(@"Yes") forKey:(NSString *)kCFUserNotificationDefaultButtonTitleKey];
		[dict setObject:local(@"No") forKey:(NSString *)kCFUserNotificationAlternateButtonTitleKey];
		
		/* Display a passphrase request notification. */
		notification = CFUserNotificationCreate(nil, 30, CFUserNotificationSecureTextField(0), &error, (CFDictionaryRef)dict);
		
		/* If we couldn't receive a response, return nil. */
		if((error) || (CFUserNotificationReceiveResponse(notification, 0, &response))
				|| ((response & 0x3) != kCFUserNotificationDefaultResponse))
		{
			if(((len == 1) && (buf[0] == 1)) || ((len == 5) && (buf[4] == 1))) 
			{
				/* Return \2. */
				write(src, "\0\0\0\5\2\0\0\0\0", 9);

				[pool release];
				return;
			}
		
			if(((len == 1) && (buf[0] == 11)) || ((len == 5) && (buf[4] == 11))) 
			{
				/* Return \12. */
				write(src, "\0\0\0\5\f\0\0\0\0", 9);

				[pool release];
				return;
			}
		}
	}

	if(([[self keysOnAgent] count] < 1) && ([[NSUserDefaults standardUserDefaults] boolForKey:AddKeysOnConnectionString])) 
	{

		keychain = [SSHKeychain currentKeychain];

		if((keychain != nil) && ([keychain count] > 0))
		{
			[openPanelLock lock];
			openPanel = YES;
			[openPanelLock unlock];
	
			[keychain addKeysToAgent];

			[openPanelLock lock];
			openPanel = NO;
			[openPanelLock unlock];
		}		
	}

	/* Write the buffer to the agent. */
	write(fd, buf, len);

	[pool release];
}

/* This method is called in a separate thread. It periodically checks if the ssh-agent is still alive. */
- (void)checkAgent
{
	NSAutoreleasePool *pool;
	NSMutableDictionary *dict;
	
	pool = [[NSAutoreleasePool alloc] init];

	SInt32 error;
	CFUserNotificationRef notification;
	CFOptionFlags response;
	
	while(true)
	{
		if(getpgid([self pid]) == -1)
		{
			[self stop];

			/* Dictionary for the panel. */
			dict = [NSMutableDictionary dictionary];
		
			[dict setObject:local(@"AgentTerminatedPanelTitle") forKey:(NSString *)kCFUserNotificationAlertHeaderKey];
			[dict setObject:local(@"AgentTerminatedPanelText") forKey:(NSString *)kCFUserNotificationAlertMessageKey];
		
			[dict setObject:[NSURL fileURLWithPath:[[[NSBundle mainBundle] resourcePath]
						stringByAppendingString:@"/SSHKeychain.icns"]] forKey:(NSString *)kCFUserNotificationIconURLKey];
		
			[dict setObject:local(@"Yes") forKey:(NSString *)kCFUserNotificationDefaultButtonTitleKey];
			[dict setObject:local(@"No") forKey:(NSString *)kCFUserNotificationAlternateButtonTitleKey];
		
			/* Display a passphrase request notification. */
			notification = CFUserNotificationCreate(nil, 30, CFUserNotificationSecureTextField(0), &error, (CFDictionaryRef)dict);
		
			/* If we couldn't receive a response, return nil. */
			if((error) || (CFUserNotificationReceiveResponse(notification, 0, &response)))
			{
				return;
			}
		
			/* If OK was pressed, add the keys. */
			if((response & 0x3) == kCFUserNotificationDefaultResponse)
			{
				[self start];
			}

			break;
		}
		sleep(30);
	}
	[pool release];
}

/* Get current keys on agent. */
- (NSArray *)currentKeysOnAgent
{
	int i;
	NSString *theOutput, *type;
	SSHTool *theTool;
	NSMutableArray *keys;
	NSArray *columns, *key, *lines;

	/* If the PID is < 1, we assume the agent isn't running. */
	if([self pid] < 1)
	{
		return nil;
	}

	/* Initialize a ssh-add SSHTool, set the arguments to -l for a list of keys. */
	theTool = [SSHTool toolWithName:@"ssh-add"];
	[theTool setArgument:@"-l"];

	/* Set the SSH_AUTH_SOCK environment variable so ssh-add can talk to the real agent. */
	[theTool setEnvironmentVariable:@"SSH_AUTH_SOCK" withValue:[self agentSocketPath]];

	/* Launch the tool and retrieve stdout. */
	theOutput = [theTool launchForStandardOutput];

	if(theOutput == nil)
	{
		return nil;
	}

	if([theOutput isEqualToString:@"The agent has no identities.\n"])
	{
		return nil;
	}

	/* Split the lines with delimiter "\n". */
	lines = [theOutput componentsSeparatedByString:@"\n"];

	keys = [NSMutableArray array];

	for(i=0; i < [lines count]; i++)
	{
		/* Split the line with delimiter " ". */
		columns = [[lines objectAtIndex:i] componentsSeparatedByString:@" "];

		if([columns count] == 4)
		{
			if([[columns objectAtIndex:3] isEqualToString:@"(RSA1)"])
				type = @"RSA1";
			else if([[columns objectAtIndex:3] isEqualToString:@"(RSA)"])
				type = @"RSA";
			else if([[columns objectAtIndex:3] isEqualToString:@"(DSA)"])
				type = @"DSA";
			else
				type = @"?";

			key = [NSArray arrayWithObjects:
					[NSString stringWithString:[[columns objectAtIndex:2] stringByAbbreviatingWithTildeInPath]],
					[NSString stringWithString:[columns objectAtIndex:1]], 
					[NSString stringWithString:type],
					nil];
			[keys addObject:key];
		}
	}

	if([keys count] > 0)
	{
		return [NSArray arrayWithArray:keys];
	}

	return nil;
}

/* This method is called when keys are added/removed from the agent. */
- (void)keysOnAgentStatusChange:(NSNotification *)notification
{
 	if([[notification name] isEqualToString:@"AgentEmptied"])
 	{
		[keysOnAgentLock lock];
		if(keysOnAgent)
		{
			[keysOnAgent release];
		}

		keysOnAgent = nil;
		
		[keysOnAgentLock unlock];
 	}

	else if([[notification name] isEqualToString:@"AgentFilled"])
 	{
		[keysOnAgentLock lock];
		keysOnAgent = [[[SSHAgent currentAgent] currentKeysOnAgent] retain];
		[keysOnAgentLock unlock];
	}

}

@end