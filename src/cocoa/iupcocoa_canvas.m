/** \file
 * \brief Canvas Control
 *
 * See Copyright Notice in "iup.h"
 */

#include <Cocoa/Cocoa.h>

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <memory.h>
#include <stdarg.h>
#include <limits.h>

#include "iup.h"
#include "iupcbs.h"

#include "iup_object.h"
#include "iup_layout.h"
#include "iup_attrib.h"
#include "iup_dialog.h"
#include "iup_str.h"
#include "iup_drv.h"
#include "iup_drvinfo.h"
#include "iup_drvfont.h"
#include "iup_canvas.h"
#include "iup_key.h"
#include "iup_class.h" // needed for iup_classbase.h
#include "iup_classbase.h" // iupROUND
#include "iup_focus.h"

#include "iupcocoa_draw.h" // struct _IdrawCanvas

#include "iupcocoa_drv.h"


// I'm undecided if we should subclass NSView or NSControl.
// IUP wants to use Canvas for fake controls and the enabled property is useful.
// However the other properties (so far) don't seem that useful.
// I have been worried about subtle behaviors like key loops and input that I may not be aware of that NSControl may handle,
// but so far tracking down key loop problems, I've found that NSControl did nothing to help.
// So far NSView seems to be sufficient, as long as I implement the enabled property and make sure none of the other code checks for [NSControl class].
// (I had to replace some instances of that with respondsToSelector() on isEnabled/setEnabled: in Common.)
@interface IupCocoaCanvasView : NSView
{
	Ihandle* _ih;
	struct _IdrawCanvas* _dc;
	bool _isCurrentKeyWindow;
	bool _isCurrentFirstResponder;
}
@property(nonatomic, assign) Ihandle* ih;
@property(nonatomic, assign) struct _IdrawCanvas* dc;
@property(nonatomic, assign, getter=isCurrentKeyWindow, setter=setCurrentKeyWindow:) bool currentKeyWindow;
@property(nonatomic, assign, getter=isCurrentFirstResponder, setter=setCurrentFirstResponder:) bool currentFirstResponder;
@property(nonatomic, assign, getter=isEnabled, setter=setEnabled:) BOOL enabled; // provided by NSControl, must define if we are NSView
- (void) updateFocus;

@end

@implementation IupCocoaCanvasView
@synthesize ih = _ih;
@synthesize dc = _dc;
@synthesize currentKeyWindow = _isCurrentKeyWindow;
@synthesize currentFirstResponder = _isCurrentFirstResponder;

- (instancetype) initWithFrame:(NSRect)frame_rect ih:(Ihandle*)ih
{
	self = [super initWithFrame:frame_rect];
	if(self)
	{
		_ih = ih;

//		iupAttribSetDouble(ih, "_IUPAPPLE_CGWIDTH", frame_rect.size.width);
//		iupAttribSetDouble(ih, "_IUPAPPLE_CGHEIGHT", frame_rect.size.height);
		// Enabling layer backed views works around drawing corruption caused by native focus rings, but has all the consequences of using layer-backed views.
		// Apple Bug ID: 44545497
//		[self setWantsLayer:YES];
#if 1
		[self setPostsBoundsChangedNotifications:YES];

		// Surprisingly, NSView doesn't have a built in method for resize events, but instead we muse use NSNotificationCenter
		NSNotificationCenter* notification_center = [NSNotificationCenter defaultCenter];
		[notification_center addObserver:self
			selector:@selector(frameDidChangeNotification:)
			name:NSViewFrameDidChangeNotification
			object:self
		];
		[notification_center addObserver:self
			selector:@selector(windowDidBecomeKeyNotification:)
			name:NSWindowDidBecomeKeyNotification
			object:[self window]
		];
		[notification_center addObserver:self
			selector:@selector(windowDidResignKeyNotification:)
			name:NSWindowDidResignKeyNotification
			object:[self window]
		];
		[self setEnabled:YES];
#endif
		
	}
	return self;
}

- (void) dealloc
{
	NSNotificationCenter* notification_center = [NSNotificationCenter defaultCenter];
	[notification_center removeObserver:self];
	[super dealloc];
}

- (void) drawRect:(NSRect)the_rect
{
	Ihandle* ih = _ih;

	[self lockFocus];

	// Obtain the Quartz context from the current NSGraphicsContext at the time the view's
	// drawRect method is called. This context is only appropriate for drawing in this invocation
	// of the drawRect method.
	// Interesting: graphicsPort is deprecated in 10.10
	// CGContextRef cg_context = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
	// Use [[NSGraphicsContext currentContext] CGContext] in 10.10+
	CGContextRef cg_context = [[NSGraphicsContext currentContext] CGContext];
	
	
	struct _IdrawCanvas* dc = [self dc];

	if(dc != NULL)
	{
//		CGContextRelease(dc->cgContext);
		// I'm concerned about the context changing out from under us,
		// (e.g. plug in new monitor, switch resolution, change multi-monitor-spanning, switch GPUs)
		// so always reset the cgContext. Inside the Draw implementation, the CGContext should always reference this pointer and be up-to-date.
		dc->cgContext = cg_context;
//		CGContextRetain(dc->cgContext);
	}
	
	
	CGContextSaveGState(cg_context);

	// IUP has inverted y-coordinates compared to Cocoa (which uses Cartesian like OpenGL and your math books)
	// If we are clever, we can invert the transform matrix so that the rest of the drawing code doesn't need to care.
	{
		// just inverting the y-scale causes the rendered area to flip off-screen. So we need to shift the canvas so it is centered before inverting it.
		CGFloat translate_y = the_rect.size.height * 0.5;
		CGContextTranslateCTM(cg_context, 0.0, +translate_y);
		CGContextScaleCTM(cg_context, 1.0,  -1.0);
		CGContextTranslateCTM(cg_context, 0.0, -translate_y);
	}
	
	IFnff call_back = (IFnff)IupGetCallback(ih, "ACTION");
	if(call_back)
	{
		call_back(ih, ih->data->posx, ih->data->posy);
	}
	CGContextRestoreGState(cg_context);

	[self unlockFocus];
}



// Note: This also triggers when the view is moved, not just resize.
- (void) frameDidChangeNotification:(NSNotification*)the_notification
{
// This Notification does not provide a userInfo dictionary according to the docs
	NSRect view_frame = [self frame];
	Ihandle* ih = _ih;

	struct _IdrawCanvas* dc = [self dc];
	CGFloat old_width = 0.0;
	CGFloat old_height = 0.0;
	if(dc != NULL)
	{
		old_width = dc->w;
		old_height = dc->h;
	}

//	CGFloat old_width = iupAttribGetDouble(ih, "_IUPAPPLE_CGWIDTH");
//	CGFloat old_height = iupAttribGetDouble(ih, "_IUPAPPLE_CGHEIGHT");

	if((old_width == view_frame.size.width) && (old_height == view_frame.size.height))
	{
		// Means we were moved, but not resized.
		return;
	}

//	iupAttribSetDouble(ih, "_IUPAPPLE_CGWIDTH", view_frame.size.width);
//	iupAttribSetDouble(ih, "_IUPAPPLE_CGHEIGHT", view_frame.size.height);
	if(dc != NULL)
	{
		dc->w = view_frame.size.width;
		dc->h = view_frame.size.height;

		// Just in case they try to draw in the resize callback, let's make sure the CGContext is still valid.
		CGContextRef cg_context = [[NSGraphicsContext currentContext] CGContext];

		// I'm concerned about the context changing out from under us,
		// (e.g. plug in new monitor, switch resolution, change multi-monitor-spanning, switch GPUs)
		// so always reset the cgContext. Inside the Draw implementation, the CGContext should always reference this pointer and be up-to-date.
		dc->cgContext = cg_context;
	}
	
	IFnii call_back = (IFnii)IupGetCallback(ih, "RESIZE_CB");
	if(call_back)
	{
		call_back(ih, view_frame.size.width, view_frame.size.height);
	}
}


- (void) windowDidBecomeKeyNotification:(NSNotification*)the_notification
{
//	NSLog(@"window became key");
	[self setCurrentKeyWindow:true];
	[self updateFocus];

}
- (void) windowDidResignKeyNotification:(NSNotification*)the_notification
{
//	NSLog(@"window resigned");
	[self setCurrentKeyWindow:false];
	[self updateFocus];
}

//////// Keyboard stuff

- (BOOL) acceptsFirstResponder
{
//	BOOL ret_flag = [super acceptsFirstResponder];
#if 1
	if([self isEnabled])
	{
//NSLog(@"acceptsFirstResponder:YES");
		return YES;
	}
	else
	{
//NSLog(@"acceptsFirstResponder:NO");
		return NO;
	}
#else
	return YES;
#endif
}

/*
Apple doc:
The default value of this property is NO.
Subclasses can override this property and use their implementation to determine if the view requires its panel
to become the key window so that it can handle keyboard input and navigation.
Such a subclass should also override acceptsFirstResponder to return YES.
This property is also used in keyboard navigation.
It determines if a mouse click should give focus to a view—that is, make it the first responder).
Some views (for example, text fields) want to receive the keyboard focus when you click in them.
Other views (for example, buttons) receive focus only when you tab to them.
You wouldn't want focus to shift from a textfield that has editing in progress simply because you clicked on a check box.

Sooo... since IUP uses this mostly for buttons and not text entry, it seems like we should return NO.
But this means that the widgets will never get the focus ring.
*/
- (BOOL) needsPanelToBecomeKey
{
	// Should we also test [[NSApplication sharedApplication] isFullKeyboardAccessEnabled]?
//	BOOL ret_flag = [super needsPanelToBecomeKey];
//	return YES;

	// TODO: We should create a new ATTRIBUTE to distinguish different behavior modes, e.g.
	// FOCUSMODE=
	// BUTTON - returns no here so if the user is typing in another field and clicks this "button", the focus won't change
	// TEXTFIELD - text entry things are handled, but things like TAB to switch focus are passed up the responder chain
	// ALL - all entry is handled by the user

	Ihandle* ih = _ih;

	// FOR NOW: Hardcode/hack until I sort this out
	if(IupClassMatch(ih, "flatbutton")
		|| IupClassMatch(ih, "flatseparator")
		|| IupClassMatch(ih, "dropbutton")
		|| IupClassMatch(ih, "flattoggle")
		|| IupClassMatch(ih, "flatlabel")
		|| IupClassMatch(ih, "colorbar")
		|| IupClassMatch(ih, "colorbrowser")
		|| IupClassMatch(ih, "dial")
		|| IupClassMatch(ih, "flatseparator")
		|| IupClassMatch(ih, "flatscrollbox")
		|| IupClassMatch(ih, "gauge")
		|| IupClassMatch(ih, "flatseparator")
		|| IupClassMatch(ih, "flatframe")
		|| IupClassMatch(ih, "flattabs")
	)
	{
		return NO;
	}
	else
	{
		return YES;
	}
}

- (BOOL) canBecomeKeyView
{
//	BOOL ret_flag = [super canBecomeKeyView];
#if 0
	// Should we also test [[NSApplication sharedApplication] isFullKeyboardAccessEnabled]?
	if([self isEnabled])
	{
//NSLog(@"canBecomeKeyView:YES");
		return YES;
	}
	else
	{
//NSLog(@"canBecomeKeyView:NO");
		return NO;
	}
#else
	return YES;
#endif
}

- (BOOL) becomeFirstResponder
{
//NSLog(@"becomeFirstResponder");
#if 1
	BOOL ret_val = [super becomeFirstResponder];
	[self setCurrentFirstResponder:ret_val];
	[self updateFocus];



	return ret_val;
#else
	[self setCurrentFirstResponder:true];
	[self updateFocus];
	return YES;
#endif
}

- (BOOL) resignFirstResponder
{
//NSLog(@"resignFirstResponder");
#if 1
	BOOL ret_val = [super resignFirstResponder];
	[self setCurrentFirstResponder:!ret_val];

	[self updateFocus];
	return ret_val;

#else
	[self setCurrentFirstResponder:false];

	[self updateFocus];
	return YES;
#endif



}

// !0.7 API for native focus ring
- (void)drawFocusRingMask
{
//	[self lockFocus];
//	[NSGraphicsContext currentContext];
	
    NSRectFill([self bounds]);
//	[self unlockFocus];
//	[[self window] setViewsNeedDisplay:YES];
}

// !0.7 API for native focus ring
- (NSRect)focusRingMaskBounds
{
    return [self bounds];
}

// helper API to notify IUP of focus state change
- (void) updateFocus
{
	Ihandle* ih = _ih;
	if([self isCurrentKeyWindow] && [self isCurrentFirstResponder])
	{
		iupCallGetFocusCb(ih);

	}
	else
	{
		iupCallKillFocusCb(ih);

	}
}

- (BOOL) acceptsFirstMouse:(NSEvent *)theEvent
{
	return YES;
}
#if 1
- (void) flagsChanged:(NSEvent*)the_event
{
	// Don't respond if the control is inactive
	if(![self isEnabled])
	{
		return;
	}

//	NSLog(@"flagsChanged: %@", the_event);
//	NSLog(@"modifierFlags: 0x%X", [the_event modifierFlags]);
/*
    NSEventModifierFlagCapsLock           = 1 << 16, // Set if Caps Lock key is pressed.
    NSEventModifierFlagShift              = 1 << 17, // Set if Shift key is pressed.
    NSEventModifierFlagControl            = 1 << 18, // Set if Control key is pressed.
    NSEventModifierFlagOption             = 1 << 19, // Set if Option or Alternate key is pressed.
    NSEventModifierFlagCommand            = 1 << 20, // Set if Command key is pressed.
    NSEventModifierFlagNumericPad         = 1 << 21, // Set if any key in the numeric keypad is pressed.
    NSEventModifierFlagHelp               = 1 << 22, // Set if the Help key is pressed.
    NSEventModifierFlagFunction           = 1 << 23, // Set if any function key is pressed.
*/
	Ihandle* ih = [self ih];
    unsigned short mac_key_code = [the_event keyCode];
//    NSLog(@"mac_key_code : %d", mac_key_code);
	bool should_not_propagate = iupCocoaModifierEvent(ih, the_event, (int)mac_key_code);
	if(!should_not_propagate)
	{
		[super flagsChanged:the_event];
	}
}

- (void) keyDown:(NSEvent*)the_event
{
 	// Don't respond if the control is inactive
	if(![self isEnabled])
	{
		return;
	}
	   // gets ihandle
    Ihandle* ih = [self ih];
//	NSLog(@"keyDown: %@", the_event);
    unsigned short mac_key_code = [the_event keyCode];
//    NSLog(@"keydown string: %d", mac_key_code);

	bool should_not_propagate = iupCocoaKeyEvent(ih, the_event, (int)mac_key_code, true);
	if(!should_not_propagate)
	{
		[super keyDown:the_event];
	}
}

- (void) keyUp:(NSEvent*)the_event
{
	// Don't respond if the control is inactive
	if(![self isEnabled])
	{
		return;
	}
	
	Ihandle* ih = [self ih];
    unsigned short mac_key_code = [the_event keyCode];
	bool should_not_propagate = iupCocoaKeyEvent(ih, the_event, (int)mac_key_code, false);
	if(!should_not_propagate)
	{
		[super keyUp:the_event];
	}
}
#endif

//////// Mouse stuff

- (void) mouseDown:(NSEvent*)the_event
{
	// Don't respond if the control is inactive
	if(![self isEnabled])
	{
		return;
	}
	
	Ihandle* ih = _ih;
	bool should_not_propagate = iupCocoaCommonBaseHandleMouseButtonCallback(ih, the_event, self, true);
	if(!should_not_propagate)
	{
		[super mouseDown:the_event];
	}
}

- (void) mouseDragged:(NSEvent*)the_event
{
	// Don't respond if the control is inactive
	if(![self isEnabled])
	{
		return;
	}
	
	Ihandle* ih = _ih;
	bool should_not_propagate = iupCocoaCommonBaseHandleMouseMotionCallback(ih, the_event, self);
	if(!should_not_propagate)
	{
		[super mouseDragged:the_event];
	}
}

- (void) mouseUp:(NSEvent*)the_event
{
	// Don't respond if the control is inactive
	if(![self isEnabled])
	{
		return;
	}
	
	Ihandle* ih = _ih;
	bool should_not_propagate = iupCocoaCommonBaseHandleMouseButtonCallback(ih, the_event, self, false);
	if(!should_not_propagate)
	{
		[super mouseUp:the_event];
	}
}

// I learned that if I don't call super, the context menu doesn't activate.
- (void) rightMouseDown:(NSEvent*)the_event
{
	// Don't respond if the control is inactive
	if(![self isEnabled])
	{
		return;
	}
	
	Ihandle* ih = _ih;
	bool should_not_propagate = iupCocoaCommonBaseHandleMouseButtonCallback(ih, the_event, self, true);
	if(!should_not_propagate)
	{
		[super rightMouseDown:the_event];
	}
}

- (void) rightMouseDragged:(NSEvent*)the_event
{
	// Don't respond if the control is inactive
	if(![self isEnabled])
	{
		return;
	}
	
	Ihandle* ih = _ih;
	bool should_not_propagate = iupCocoaCommonBaseHandleMouseMotionCallback(ih, the_event, self);
	if(!should_not_propagate)
	{
		[super rightMouseDragged:the_event];
	}
}

- (void) rightMouseUp:(NSEvent*)the_event
{
	// Don't respond if the control is inactive
	if(![self isEnabled])
	{
		return;
	}
	
	Ihandle* ih = _ih;
	bool should_not_propagate = iupCocoaCommonBaseHandleMouseButtonCallback(ih, the_event, self, false);
	if(!should_not_propagate)
	{
		[super rightMouseUp:the_event];
	}
}

- (void) otherMouseDown:(NSEvent*)the_event
{
	// Don't respond if the control is inactive
	if(![self isEnabled])
	{
		return;
	}
	
	Ihandle* ih = _ih;
	bool should_not_propagate = iupCocoaCommonBaseHandleMouseButtonCallback(ih, the_event, self, true);
	if(!should_not_propagate)
	{
		[super otherMouseDown:the_event];
	}
}

- (void) otherMouseDragged:(NSEvent*)the_event
{
	// Don't respond if the control is inactive
	if(![self isEnabled])
	{
		return;
	}
	
	Ihandle* ih = _ih;
	bool should_not_propagate = iupCocoaCommonBaseHandleMouseMotionCallback(ih, the_event, self);
	if(!should_not_propagate)
	{
		[super otherMouseDragged:the_event];
	}
}

- (void) otherMouseUp:(NSEvent*)the_event
{
	// Don't respond if the control is inactive
	if(![self isEnabled])
	{
		return;
	}
	
	Ihandle* ih = _ih;
	bool should_not_propagate = iupCocoaCommonBaseHandleMouseButtonCallback(ih, the_event, self, false);
	if(!should_not_propagate)
	{
		[super otherMouseUp:the_event];
	}
}

@end


static NSView* cocoaCanvasGetRootView(Ihandle* ih)
{
	NSView* root_container_view = (NSView*)ih->handle;
	NSCAssert([root_container_view isKindOfClass:[NSView class]], @"Expected NSView");
	return root_container_view;
}

static NSScrollView* cocoaCanvasGetScrollView(Ihandle* ih)
{
	if(iupAttribGetBoolean(ih, "_IUPCOCOA_CANVAS_HAS_SCROLLBAR"))
	{
		NSScrollView* scroll_view = (NSScrollView*)ih->handle;
		NSCAssert([scroll_view isKindOfClass:[NSScrollView class]], @"Expected NSScrollView");
		return scroll_view;
	}
	else
	{
		return nil;
	}
}

static IupCocoaCanvasView* cocoaCanvasGetCanvasView(Ihandle* ih)
{
	if(iupAttribGetBoolean(ih, "_IUPCOCOA_CANVAS_HAS_SCROLLBAR"))
	{
		NSScrollView* scroll_view = cocoaCanvasGetScrollView(ih);
		IupCocoaCanvasView* canvas_view = (IupCocoaCanvasView*)[scroll_view documentView];
		NSCAssert([canvas_view isKindOfClass:[IupCocoaCanvasView class]], @"Expected IupCocoaCanvasView");
		return canvas_view;
	}
	else
	{
		IupCocoaCanvasView* canvas_view = (IupCocoaCanvasView*)ih->handle;
		return canvas_view;
	}
}

static char* cocoaCanvasGetCGContextAttrib(Ihandle* ih)
{
	IupCocoaCanvasView* canvas_view = cocoaCanvasGetCanvasView(ih);
	CGContextRef cg_context = NULL;
	[canvas_view lockFocus];
	// Interesting: graphicsPort is deprecated in 10.10
	// cg_context = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
	// Use [[NSGraphicsContext currentContext] CGContext] in 10.10+
	cg_context = [[NSGraphicsContext currentContext] CGContext];
	[canvas_view unlockFocus];
	
	return (char*)cg_context;
}

int cocoaCanvasSetIDrawCanvasAttrib(Ihandle* ih, const char* value)
{
	if(ih->handle != NULL)
	{
		IupCocoaCanvasView* canvas_view = cocoaCanvasGetCanvasView(ih);
		struct _IdrawCanvas* dc = (struct _IdrawCanvas*)value;
		if(dc != NULL)
		{
			[canvas_view setDc:dc];
		}
	}
	return 1;
}


static char* cocoaCanvasGetDrawableAttrib(Ihandle* ih)
{
	return (char*)cocoaCanvasGetCGContextAttrib(ih);
}

static char* cocoaCanvasGetDrawSizeAttrib(Ihandle *ih)
{
	int w, h;

	// scrollview or canvas view?
	IupCocoaCanvasView* canvas_view = cocoaCanvasGetCanvasView(ih);

	NSRect the_frame = [canvas_view frame];
	w = iupROUND(the_frame.size.width);
	h = iupROUND(the_frame.size.height);
	
	return iupStrReturnIntInt(w, h, 'x');
}



static int cocoaCanvasSetContextMenuAttrib(Ihandle* ih, const char* value)
{
	Ihandle* menu_ih = (Ihandle*)value;
 	IupCocoaCanvasView* canvas_view = cocoaCanvasGetCanvasView(ih);
	iupCocoaCommonBaseSetContextMenuForWidget(ih, canvas_view, menu_ih);

	return 1;
}

static int cocoaCanvasMapMethod(Ihandle* ih)
{
	NSView* root_view = nil;
	IupCocoaCanvasView* canvas_view = [[IupCocoaCanvasView alloc] initWithFrame:NSZeroRect ih:ih];
	
	if(iupAttribGetBoolean(ih, "SPIN"))
	{
		NSScrollView* scroll_view = [[NSScrollView alloc] initWithFrame:NSZeroRect];
		[scroll_view setDocumentView:canvas_view];
		[canvas_view release];
		[scroll_view setHasVerticalScroller:YES];
	
		[scroll_view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
		[canvas_view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
		
		root_view = scroll_view;
		iupAttribSet(ih, "_IUPCOCOA_CANVAS_HAS_SCROLLBAR", "1");
	}
	else
	{
		root_view = canvas_view;
	}
	
	
	ih->handle = root_view;

	
	
	// All Cocoa views shoud call this to add the new view to the parent view.
	iupCocoaAddToParent(ih);
	

	
	
	
	
	
	return IUP_NOERROR;
}

static void cocoaCanvasUnMapMethod(Ihandle* ih)
{
	id root_view = ih->handle;
	
	// Destroy the context menu ih it exists
	{
		Ihandle* context_menu_ih = (Ihandle*)iupCocoaCommonBaseGetContextMenuAttrib(ih);
		if(NULL != context_menu_ih)
		{
			IupDestroy(context_menu_ih);
		}
		iupCocoaCommonBaseSetContextMenuAttrib(ih, NULL);
	}
	
	iupCocoaRemoveFromParent(ih);
	[root_view release];
	ih->handle = NULL;
}




void iupdrvCanvasInitClass(Iclass* ic)
{
	/* Driver Dependent Class functions */
	ic->Map = cocoaCanvasMapMethod;
	ic->UnMap = cocoaCanvasUnMapMethod;
#if 0
	ic->LayoutUpdate = gtkCanvasLayoutUpdateMethod;
	
	/* Driver Dependent Attribute functions */
	
	/* Visual */
	iupClassRegisterAttribute(ic, "BGCOLOR", NULL, gtkCanvasSetBgColorAttrib, "255 255 255", NULL, IUPAF_DEFAULT);  /* force new default value */
	
	/* IupCanvas only */
#endif
	iupClassRegisterAttribute(ic, "DRAWSIZE", cocoaCanvasGetDrawSizeAttrib, NULL, NULL, NULL, IUPAF_READONLY|IUPAF_NO_INHERIT);
	
#if 0
	iupClassRegisterAttribute(ic, "DX", NULL, gtkCanvasSetDXAttrib, NULL, NULL, IUPAF_NO_INHERIT);  /* force new default value */
	iupClassRegisterAttribute(ic, "DY", NULL, gtkCanvasSetDYAttrib, NULL, NULL, IUPAF_NO_INHERIT);  /* force new default value */
	iupClassRegisterAttribute(ic, "POSX", iupCanvasGetPosXAttrib, gtkCanvasSetPosXAttrib, "0", NULL, IUPAF_NO_INHERIT);  /* force new default value */
	iupClassRegisterAttribute(ic, "POSY", iupCanvasGetPosYAttrib, gtkCanvasSetPosYAttrib, "0", NULL, IUPAF_NO_INHERIT);  /* force new default value */
#endif
	
	// TODO: Returns the CGContext. Is this the right thing, or should it be the NSGraphicsContext? Or should it be the NSView?
	iupClassRegisterAttribute(ic, "DRAWABLE", cocoaCanvasGetDrawableAttrib, NULL, NULL, NULL, IUPAF_NO_STRING);

	// Private helper, used by iupdrvDrawCreateCanvas and currently cocoaCanvasGetDrawableAttrib calls this.
	// Do not start with an underscore, because I need this to trigger the function
	iupClassRegisterAttribute(ic, "CGCONTEXT", cocoaCanvasGetCGContextAttrib, NULL, NULL, NULL, IUPAF_NO_STRING);
	// Private helper: Used to send the dc instance to the IupCanvasView. Kind of a hack, but keeping the two coordinated is tricky.
	// Do not start with an underscore, because I need this to trigger the function
	iupClassRegisterAttribute(ic, "IUPAPPLE_IDRAWCANVAS", NULL, cocoaCanvasSetIDrawCanvasAttrib, NULL, NULL, IUPAF_NO_STRING);

#if 0
	/* IupCanvas Windows or X only */
#ifndef GTK_MAC
#ifdef WIN32
	iupClassRegisterAttribute(ic, "HWND", iupgtkGetNativeWindowHandle, NULL, NULL, NULL, IUPAF_NO_STRING|IUPAF_NO_INHERIT);
#else
	iupClassRegisterAttribute(ic, "XWINDOW", iupgtkGetNativeWindowHandle, NULL, NULL, NULL, IUPAF_NO_INHERIT|IUPAF_NO_STRING);
	iupClassRegisterAttribute(ic, "XDISPLAY", (IattribGetFunc)iupdrvGetDisplay, NULL, NULL, NULL, IUPAF_READONLY|IUPAF_NOT_MAPPED|IUPAF_NO_INHERIT|IUPAF_NO_STRING);
#endif
#endif
	
	/* Not Supported */
	iupClassRegisterAttribute(ic, "BACKINGSTORE", NULL, NULL, "YES", NULL, IUPAF_NOT_SUPPORTED|IUPAF_NO_INHERIT);
#endif

//	TODO:
//	iupClassRegisterAttribute(ic, "TOUCH", NULL, NULL, NULL, NULL, IUPAF_NOT_SUPPORTED|IUPAF_NO_INHERIT);

	/* New API for view specific contextual menus (Mac only) */
	iupClassRegisterAttribute(ic, "CONTEXTMENU", iupCocoaCommonBaseGetContextMenuAttrib, cocoaCanvasSetContextMenuAttrib, NULL, NULL, IUPAF_NO_DEFAULTVALUE|IUPAF_NO_INHERIT);
}
