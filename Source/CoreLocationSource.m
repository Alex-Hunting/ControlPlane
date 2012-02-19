//
//	CoreLocationSource.m
//	ControlPlane
//
//	Created by David Jennes on 03/09/11.
//	Copyright 2011. All rights reserved.
//

#import "CoreLocationSource.h"
#import "DSLogger.h"
#import "JSONKit.h"

@interface CoreLocationSource (Private)

- (void) updateMap;
+ (BOOL) geocodeAddress: (inout NSString **) address toLocation: (out CLLocation **) location;
+ (BOOL) geocodeLocation: (in CLLocation *) location toAddress: (out NSString **) address;
- (BOOL) isValidLocation: (CLLocation *) newLocation withOldLocation:(CLLocation *) oldLocation;
+ (BOOL) convertText: (in NSString *) text toLocation: (out CLLocation **) location;
+ (NSString *) convertLocationToText: (in CLLocation *) location;

@end

@implementation CoreLocationSource

static const NSString *kGoogleAPIPrefix = @"https://maps.googleapis.com/maps/api/geocode/json?";

- (id) init {
    self = [super initWithNibNamed:@"CoreLocationRule"];
    if (!self)
        return nil;
    
	locationManager = [CLLocationManager new];
	locationManager.delegate = self;
	locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
	current = nil;
	selectedRule = nil;
	startDate = [[NSDate date] retain];
    
    mapAnnotations = [[NSMutableArray alloc] init];
    mapOverlays = [[NSMutableArray alloc] init];
	

	// for custom panel
	scriptObject = nil;
	address = @"";
	coordinates = @"0.0, 0.0";
	accuracy = @"0 m";
	htmlTemplate = @"";
	
    return self;
}

- (void)awakeFromNib {	
    [mapView setShowsUserLocation: NO];
    [mapView setDelegate: self];
    

    
    MKReverseGeocoder *reverseGeocoder = [[MKReverseGeocoder alloc] init];
    reverseGeocoder.delegate = self;
    [reverseGeocoder start];
    
    MKGeocoder *geocoderNoCoord = [[MKGeocoder alloc] init];
    geocoderNoCoord.delegate = self;
    //[geocoderNoCoord start];
    
    MKGeocoder *geocoderCoord = [[MKGeocoder alloc] init];
    geocoderCoord.delegate = self;
    [geocoderCoord start];
    
	// show empty page
	[webView setFrameLoadDelegate: self];
	[webView.mainFrame loadHTMLString:@"" baseURL:NULL];

}

- (void) dealloc {
	[locationManager stopUpdatingLocation];
	[locationManager release];
	
	[current release];
	[selectedRule release];
	
	[super dealloc];
}

- (void) start {
	if (running)
		return;
	
	[locationManager startUpdatingLocation];
	[self setDataCollected: YES];
	[self performSelectorOnMainThread: @selector(updateMap) withObject: nil waitUntilDone: NO];
	
	running = YES;
}

- (void) stop {
	if (!running)
		return;
	
	[locationManager stopUpdatingLocation];
	[self setDataCollected: NO];
	current = nil;
	
	running = NO;
}

- (NSMutableDictionary *) readFromPanel {
	NSMutableDictionary *dict = [super readFromPanel];
	
	// store values
	[dict setValue: coordinates forKey: @"parameter"];
	if (![dict objectForKey: @"description"])
		[dict setValue: address forKey: @"description"];
	
	return dict;
}

- (void) writeToPanel: (NSDictionary *) dict usingType: (NSString *) type {
	[super writeToPanel: dict usingType: type];
	NSString *add = @"";
	
	// do we already have settings?
	if ([dict objectForKey:@"parameter"]) {
		[CoreLocationSource convertText: [dict objectForKey:@"parameter"] toLocation: &selectedRule];
        [mapView setShowsUserLocation:NO];
        
        [mapView setCenterCoordinate:selectedRule.coordinate];
        MKCoordinateRegion theRegion;
        theRegion.center = [mapView centerCoordinate];
        MKCoordinateSpan theSpan = {0.0015,0.0015};
        theRegion.span = theSpan;
        
        [mapView setRegion:theRegion animated:NO];
        
        MKPointAnnotation *pin = [[[MKPointAnnotation alloc] init] autorelease];
        pin.coordinate = [mapView centerCoordinate];
        pin.title = @"";
        [mapView addAnnotation:pin];
        
    }
	else {
        [mapView setShowsUserLocation:YES];
        MKCoordinateRegion theRegion;
        theRegion.center = [mapView centerCoordinate];
        MKCoordinateSpan theSpan = {0.0015,0.0015};
        theRegion.span = theSpan;
        
        
        [mapView setRegion:theRegion animated:NO];

		[self setValue: add forKey: @"address"];
		selectedRule = [current copy];
    }
	
	// get corresponding address
	if (![CoreLocationSource geocodeLocation: selectedRule toAddress: &add])
		add = NSLocalizedString(@"Unknown address", @"CoreLocation");
}

- (NSString *) name {
	return @"CoreLocation";
}

- (BOOL) doesRuleMatch: (NSDictionary *) rule {
	// get coordinates of rule
	CLLocation *ruleLocation = nil;
	[CoreLocationSource convertText: [rule objectForKey:@"parameter"] toLocation: &ruleLocation];
	
	// match if distance is smaller than accuracy
	if (ruleLocation && current)
		return [ruleLocation distanceFromLocation: current] <= current.horizontalAccuracy;
	else
		return 0;
}

- (IBAction) showCoreLocation: (id) sender {
	NSString *add = nil;
	
	selectedRule = [current copy];
	if (![CoreLocationSource geocodeLocation: selectedRule toAddress: &add])
		add = NSLocalizedString(@"Unknown address", @"CoreLocation");

    
    MKCoordinateRegion theRegion;
    theRegion.center = [current coordinate];
    MKCoordinateSpan theSpan = {0.001,0.001};
    theRegion.span = theSpan;

    [mapView setRegion:theRegion animated:YES];
    // show values
	[self setValue: [CoreLocationSource convertLocationToText: selectedRule] forKey: @"coordinates"];
	[self setValue: add forKey: @"address"];
	[self performSelectorOnMainThread: @selector(updateMap) withObject: nil waitUntilDone: NO];
}

#pragma mark -
#pragma mark UI Validation

- (BOOL) validateAddress: (inout NSString **) newValue error: (out NSError **) outError {
	CLLocation *loc = nil;
	
	// check address
	BOOL result = [CoreLocationSource geocodeAddress: newValue toLocation: &loc];
	
	// if correct, set coordinates
	if (result) {
		selectedRule = loc;
		
		[self setValue: [CoreLocationSource convertLocationToText: loc] forKey: @"coordinates"];
		[self setValue: *newValue forKey: @"address"];
		[self performSelectorOnMainThread: @selector(updateMap) withObject: nil waitUntilDone: NO];
	}
	
	return result;
}

- (BOOL) validateCoordinates: (inout NSString **) newValue error: (out NSError **) outError {
	CLLocation *loc = nil;
	NSString *add = nil;
	
	// check coordinates
	BOOL result = [CoreLocationSource convertText: *newValue toLocation: &loc];
	
	// if correct, set address
	if (result) {
		selectedRule = loc;
		[CoreLocationSource geocodeLocation: loc toAddress: &add];
		
		[self setValue: *newValue forKey: @"coordinates"];
		[self setValue: add forKey: @"address"];
		[self performSelectorOnMainThread: @selector(updateMap) withObject: nil waitUntilDone: NO];
	}
	
	return result;
}

#pragma mark -
#pragma mark JavaScript stuff

- (void) updateSelectedWithLatitude: (NSNumber *) latitude andLongitude: (NSNumber *) longitude {
	NSString *add = nil;
	
	selectedRule = [[CLLocation alloc] initWithLatitude: [latitude doubleValue] longitude: [longitude doubleValue]];
	if (![CoreLocationSource geocodeLocation: selectedRule toAddress: &add])
		add = NSLocalizedString(@"Unknown address", @"CoreLocation");
	
	// show values
	[self setValue: [CoreLocationSource convertLocationToText: selectedRule] forKey: @"coordinates"];
	[self setValue: add forKey: @"address"];
}

- (void) webView: (WebView *) sender didFinishLoadForFrame: (WebFrame *) frame {
	if (frame == [frame findFrameNamed:@"_top"]) {
		scriptObject = [sender windowScriptObject];
		[scriptObject setValue: self forKey:@"cocoa"];
	}
}

+ (BOOL) isSelectorExcludedFromWebScript: (SEL) selector {
	if (selector == @selector(updateSelectedWithLatitude:andLongitude:)) {
		return NO;
	}
	
	return YES;
}

+ (NSString *) webScriptNameForSelector: (SEL) sel {
	if (sel == @selector(updateSelectedWithLatitude:andLongitude:))
		return @"updateSelected";
	
	return nil;
}

#pragma mark -
#pragma mark CoreLocation callbacks

- (void) locationManager: (CLLocationManager *) manager
	 didUpdateToLocation: (CLLocation *) newLocation
			fromLocation: (CLLocation *) oldLocation {
	
	// Ignore invalid updates
	if (![self isValidLocation: newLocation withOldLocation: oldLocation])
		return;
	
	// location
	current = [newLocation copy];
	CLLocationDegrees lat = current.coordinate.latitude;
	CLLocationDegrees lon = current.coordinate.longitude;
	CLLocationAccuracy acc = current.horizontalAccuracy;
	DSLog(@"New location: (%f, %f) with accuracy %f", lat, lon, acc);
	
	// store
	[self setValue: [NSString stringWithFormat: @"%d m", (int) acc] forKey: @"accuracy"];
}

- (void) locationManager: (CLLocationManager *) manager didFailWithError: (NSError *) error {
	DSLog(@"Location manager failed with error: %@", [error localizedDescription]);
	
	switch (error.code) {
		case kCLErrorDenied:
			DSLog(@"Core Location denied!");
			[self stop];
			break;
		default:
			break;
	}
}

#pragma mark -
#pragma mark Helper functions

- (void) updateMap {
	// Get coordinates and replace placeholders with these
	NSString *htmlString = [NSString stringWithFormat: htmlTemplate,
							(current ? current.coordinate.latitude : 0.0),
							(current ? current.coordinate.longitude : 0.0),
							(selectedRule ? selectedRule.coordinate.latitude : 0.0),
							(selectedRule ? selectedRule.coordinate.longitude : 0.0),
							(current ? current.horizontalAccuracy : 0.0)];
	
	// Load the HTML in the WebView
	[webView.mainFrame loadHTMLString: htmlString baseURL: nil];
}

+ (BOOL) geocodeAddress: (NSString **) address toLocation: (CLLocation **) location {
	NSString *param = [*address stringByAddingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
	NSString *url = [NSString stringWithFormat: @"%@address=%@&sensor=false", kGoogleAPIPrefix, param];
	DSLog(@"%@", url);
	
	// fetch and parse response
	NSData *jsonData = [NSData dataWithContentsOfURL: [NSURL URLWithString: url]];
	if (!jsonData)
		return NO;
	NSDictionary *data = [[JSONDecoder decoder] objectWithData: jsonData];
	
	// check response status
	if (![[data objectForKey: @"status"] isEqualToString: @"OK"])
		return NO;
	
	// check number of results
	if ([[data objectForKey: @"results"] count] == 0)
		return NO;
	NSDictionary *result = [[data objectForKey: @"results"] objectAtIndex: 0];
	
	*address = [[result objectForKey: @"formatted_address"] copy];
	double lat = [[[[result objectForKey: @"geometry"] objectForKey: @"location"] objectForKey: @"lat"] doubleValue];
	double lon = [[[[result objectForKey: @"geometry"] objectForKey: @"location"] objectForKey: @"lng"] doubleValue];
	*location = [[CLLocation alloc] initWithLatitude: lat longitude: lon];
	
	return YES;
}

+ (BOOL) geocodeLocation: (CLLocation *) location toAddress: (NSString **) address {
	NSString *url = [NSString stringWithFormat: @"%@latlng=%f,%f&sensor=false",
					 kGoogleAPIPrefix, location.coordinate.latitude, location.coordinate.longitude];
	
	// fetch and parse response
	NSData *jsonData = [NSData dataWithContentsOfURL: [NSURL URLWithString: url]];
	if (!jsonData)
		return NO;
	NSDictionary *data = [[JSONDecoder decoder] objectWithData: jsonData];
	
	// check response status
	if (![[data objectForKey: @"status"] isEqualToString: @"OK"])
		return NO;
	
	// check number of results
	NSArray *results = [data objectForKey: @"results"];
	if ([results count] == 0)
		return NO;
	
	*address = [[results objectAtIndex: 0] objectForKey: @"formatted_address"];
	return YES;
}

- (BOOL) isValidLocation: (CLLocation *) newLocation withOldLocation:(CLLocation *) oldLocation {
	// Filter out nil locations
	if (!newLocation)
		return NO;
	
	// Filter out points by invalid accuracy
	if (newLocation.horizontalAccuracy < 0)
		return NO;
	
	// Filter out points that are out of order
	NSTimeInterval secondsSinceLastPoint = [newLocation.timestamp timeIntervalSinceDate: oldLocation.timestamp];
	if (secondsSinceLastPoint < 0)
		return NO;

	// Filter out points created before the manager was initialized
	NSTimeInterval secondsSinceManagerStarted = [newLocation.timestamp timeIntervalSinceDate: startDate];
	if (secondsSinceManagerStarted < 0)
		return NO;
	
	// The newLocation is good to use
	return YES;
}

+ (BOOL) convertText: (in NSString *) text toLocation: (out CLLocation **) location {
	double lat = 0.0, lon = 0.0;
	
	// split
	NSArray *comp = [text componentsSeparatedByString: @","];
	if ([comp count] != 2)
		return NO;
	
	// get values
	lat = [[comp objectAtIndex: 0] doubleValue];
	lon = [[comp objectAtIndex: 1] doubleValue];
    DSLog(@"lat/long of the rule is %f/%f", lat,lon);
	*location = [[CLLocation alloc] initWithLatitude: lat longitude: lon];
	
	return YES;
}

+ (NSString *) convertLocationToText: (in CLLocation *) location {
	return [NSString stringWithFormat: @"%f,%f", location.coordinate.latitude, location.coordinate.longitude];
}

#pragma mark -
#pragma mark MKMapKit delegates
- (MKOverlayView *)mapView:(MKMapView *)aMapView viewForOverlay:(id <MKOverlay>)overlay
{
    DSLog(@"hi");
    MKCircleView *circleView = [[[MKCircleView alloc] initWithCircle:overlay] autorelease];
    return circleView;
    
    MKPolygonView *polygonView = [[[MKPolygonView alloc] initWithPolygon:overlay] autorelease];
    return polygonView;
}

- (void)reverseGeocoder:(MKReverseGeocoder *)geocoder didFindPlacemark:(MKPlacemark *)placemark {
    
}

- (void)reverseGeocoder:(MKReverseGeocoder *)geocoder didFailWithError:(NSError *)error {
    
}

- (void)geocoder:(MKGeocoder *)geocoder didFindCoordinate:(CLLocationCoordinate2D)coordinate {
    
}

- (void)geocoder:(MKGeocoder *)geocoder didFailWithError:(NSError *)error {

}

- (void)mapViewDidFinishLoadingMap:(MKMapView *)mapView {
    DSLog(@"got map finished loading");
}

- (void)mapViewDidFailLoadingMap:(MKMapView *)mapView withError:(NSError *)error {
    DSLog(@"got map failed to load");
}

- (MKAnnotationView *)mapView:(MKMapView *)aMapView viewForAnnotation:(id <MKAnnotation>)annotation {

    MKPinAnnotationView *view = [[[MKPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:@"pinmarker"] autorelease];
    view.draggable = YES;

    return view;
}
@end
