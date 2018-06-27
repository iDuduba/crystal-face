using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.System as Sys;
using Toybox.Lang as Lang;
using Toybox.Application as App;
using Toybox.ActivityMonitor as ActivityMonitor;
using Toybox.SensorHistory as SensorHistory;

class CrystalView extends Ui.WatchFace {
	private var mIsSleeping = false;
	private var mSettingsChangedSinceLastDraw = false; // Have settings changed since last full update?

	private var mHoursFont;
	private var mMinutesFont;
	private var mSecondsFont;

	private var mIconsFont;
	private var mNormalFont;

	private var mTime;
	private var mFields;
	
	private var GOAL_TYPES = {
		App.GOAL_TYPE_STEPS => :GOAL_TYPE_STEPS,
		App.GOAL_TYPE_FLOORS_CLIMBED => :GOAL_TYPE_FLOORS_CLIMBED,
		App.GOAL_TYPE_ACTIVE_MINUTES => :GOAL_TYPE_ACTIVE_MINUTES,
		
		-1 => :GOAL_TYPE_BATTERY,
		-2 => :GOAL_TYPE_CALORIES
	};

	private var ICON_FONT_CHARS = {
		:GOAL_TYPE_STEPS => "0",
		:GOAL_TYPE_FLOORS_CLIMBED => "1",
		:GOAL_TYPE_ACTIVE_MINUTES => "2",
		:FIELD_TYPE_HEART_RATE => "3",
		:FIELD_TYPE_BATTERY => "4",
		:FIELD_TYPE_BATTERY_HIDE_PERCENT => "4",
		:FIELD_TYPE_NOTIFICATIONS => "5",
		:FIELD_TYPE_CALORIES => "6",
		:GOAL_TYPE_CALORIES => "6", // Use calories icon for both field and goal.
		:FIELD_TYPE_DISTANCE => "7",
		:INDICATOR_BLUETOOTH => "8",
		:GOAL_TYPE_BATTERY => "9",
		:FIELD_TYPE_ALARMS => ":",
		:FIELD_TYPE_ALTITUDE => ";",
		:FIELD_TYPE_TEMPERATURE => "<"
	};

	// Cache references to drawables immediately after layout, to avoid expensive findDrawableById() calls in onUpdate();
	private var mDrawables = {};

	const BATTERY_FILL_WIDTH = 18;
	const BATTERY_FILL_HEIGHT = 6;

	const BATTERY_WIDTH_SMALL = 24;
	const BATTERY_FILL_WIDTH_SMALL = 15;
	const BATTERY_FILL_HEIGHT_SMALL = 4;

	const BATTERY_LEVEL_LOW = 20;
	const BATTERY_LEVEL_CRITICAL = 10;

	const CM_PER_KM = 100000;
	const MI_PER_KM = 0.621371;
	const FT_PER_M = 3.28084;

	const MAX_FIELD_LENGTH = 4; // Maximum number of characters per field;

	// N.B. Not all watches that support SDK 2.3.0 support per-second updates e.g. 735xt.
	const PER_SECOND_UPDATES_SUPPORTED = Ui.WatchFace has :onPartialUpdate;

	function initialize() {
		WatchFace.initialize();
	}

	// Load your resources here
	function onLayout(dc) {
		mHoursFont = Ui.loadResource(Rez.Fonts.HoursFont);
		mMinutesFont = Ui.loadResource(Rez.Fonts.MinutesFont);
		mSecondsFont = Ui.loadResource(Rez.Fonts.SecondsFont);

		mIconsFont = Ui.loadResource(Rez.Fonts.IconsFont);
		mNormalFont = Ui.loadResource(Rez.Fonts.NormalFont);

		setLayout(Rez.Layouts.WatchFace(dc));

		cacheDrawables();

		// Cache reference to ThickThinTime, for use in low power mode. Saves nearly 5ms!
		// Slighly faster than mDrawables lookup.
		mTime = View.findDrawableById("Time");
		mTime.setFonts(mHoursFont, mMinutesFont, mSecondsFont);

		mFields = View.findDrawableById("DataFields");
		mFields.setFonts(mIconsFont, mNormalFont);

		setHideSeconds(App.getApp().getProperty("HideSeconds"));
	}

	function cacheDrawables() {
		mDrawables[:LeftGoalMeter] = View.findDrawableById("LeftGoalMeter");
		mDrawables[:LeftGoalIcon] = View.findDrawableById("LeftGoalIcon");
		mDrawables[:LeftGoalCurrent] = View.findDrawableById("LeftGoalCurrent");
		mDrawables[:LeftGoalMax] = View.findDrawableById("LeftGoalMax");

		mDrawables[:RightGoalMeter] = View.findDrawableById("RightGoalMeter");
		mDrawables[:RightGoalIcon] = View.findDrawableById("RightGoalIcon");
		mDrawables[:RightGoalCurrent] = View.findDrawableById("RightGoalCurrent");
		mDrawables[:RightGoalMax] = View.findDrawableById("RightGoalMax");

		mDrawables[:LeftFieldIcon] = View.findDrawableById("LeftFieldIcon");
		mDrawables[:LeftFieldValue] = View.findDrawableById("LeftFieldValue");

		mDrawables[:CenterFieldIcon] = View.findDrawableById("CenterFieldIcon");
		mDrawables[:CenterFieldValue] = View.findDrawableById("CenterFieldValue");

		mDrawables[:RightFieldIcon] = View.findDrawableById("RightFieldIcon");
		mDrawables[:RightFieldValue] = View.findDrawableById("RightFieldValue");

		mDrawables[:Date] = View.findDrawableById("Date");

		mDrawables[:Bluetooth] = View.findDrawableById("Bluetooth");

		// Use mTime instead.
		//mDrawables[:Time] = View.findDrawableById("Time");

		// Use mFields instead.
		//mDrawables[:DataFields] = View.findDrawableById("DataFields");

		mDrawables[:MoveBar] = View.findDrawableById("MoveBar");
	}

	// Called when this View is brought to the foreground. Restore
	// the state of this View and prepare it to be shown. This includes
	// loading resources into memory.
	function onShow() {
	}

	// Set flag to respond to settings change on next full draw (onUpdate()), as we may be in 1Hz (lower power) mode, and cannot
	// update the full screen immediately. This is true on real hardware, but not in the simulator, which calls onUpdate()
	// immediately. Ui.requestUpdate() does not appear to work in 1Hz mode on real hardware.
	function onSettingsChanged() {
		mSettingsChangedSinceLastDraw = true;
	}

	function onSettingsChangedSinceLastDraw() {

		// Recreate background buffers for each meter, in case theme colour has changed.
		mDrawables[:LeftGoalMeter].onSettingsChanged();
		mDrawables[:RightGoalMeter].onSettingsChanged();

		mDrawables[:MoveBar].onSettingsChanged();

		// If watch does not support per-second updates, and watch is sleeping, do not show seconds immediately, as they will not 
		// update. Instead, wait for next onExitSleep(). 
		if (PER_SECOND_UPDATES_SUPPORTED || !mIsSleeping) { 
			setHideSeconds(App.getApp().getProperty("HideSeconds")); 
		} 

		mSettingsChangedSinceLastDraw = false;
	}

	// Update the view
	function onUpdate(dc) {
		System.println("onUpdate()");

		// Respond now to any settings change since last full draw, as we can now update the full screen.
		if (mSettingsChangedSinceLastDraw) {
			onSettingsChangedSinceLastDraw();
		}

		// Clear any partial update clipping.
		if (dc has :clearClip) {
			dc.clearClip();
		}

		updateGoalMeters();
		updateBluetoothIndicator();

		// Call the parent onUpdate function to redraw the layout
		View.onUpdate(dc);

		// Additional drawing on top of drawables.
		// TODO: Solving z-order issue forces ugly repetition (retrieval of battery value, etc.); can this be avoided?
		//onPostUpdate(dc);
	}

	function onPostUpdate(dc) {

		// Find any battery meter icons, and draw fill on top. 
		if ((FIELD_TYPES[App.getApp().getProperty("Field1Type")] == :FIELD_TYPE_BATTERY) ||
			(FIELD_TYPES[App.getApp().getProperty("Field1Type")] == :FIELD_TYPE_BATTERY_HIDE_PERCENT)) {
			fillBatteryMeter(dc, mDrawables[:LeftFieldIcon]);
		}

		if ((FIELD_TYPES[App.getApp().getProperty("Field2Type")] == :FIELD_TYPE_BATTERY) ||
			(FIELD_TYPES[App.getApp().getProperty("Field2Type")] == :FIELD_TYPE_BATTERY_HIDE_PERCENT)) {
			fillBatteryMeter(dc, mDrawables[:CenterFieldIcon]);
		}

		if ((FIELD_TYPES[App.getApp().getProperty("Field3Type")] == :FIELD_TYPE_BATTERY) ||
			(FIELD_TYPES[App.getApp().getProperty("Field3Type")] == :FIELD_TYPE_BATTERY_HIDE_PERCENT)) {
			fillBatteryMeter(dc, mDrawables[:RightFieldIcon]);
		}
	}

	function fillBatteryMeter(dc, batteryIcon) {
		// #8: battery returned as float. Use floor() to match native. Must match getDisplayInfoForFieldType().
		var batteryLevel = Math.floor(Sys.getSystemStats().battery);
		var colour;
		var fillWidth, fillHeight;

		if (batteryLevel <= BATTERY_LEVEL_CRITICAL) {
			colour = Graphics.COLOR_RED;
		} else if (batteryLevel <= BATTERY_LEVEL_LOW) {
			colour = Graphics.COLOR_YELLOW;
		} else {
			colour = App.getApp().getProperty("ThemeColour");
		}

		dc.setColor(colour, Graphics.COLOR_TRANSPARENT);

		// Layout uses small battery icon.
		if (batteryIcon.width == BATTERY_WIDTH_SMALL) {
			fillWidth = BATTERY_FILL_WIDTH_SMALL;
			fillHeight = BATTERY_FILL_HEIGHT_SMALL;
		} else {
			fillWidth = BATTERY_FILL_WIDTH;
			fillHeight = BATTERY_FILL_HEIGHT;
		}
		dc.fillRectangle(
			batteryIcon.locX - (fillWidth / 2) - 1,
			batteryIcon.locY - (fillHeight / 2) + 1,
			Math.ceil(fillWidth * (batteryLevel / 100)), 
			fillHeight);	
	}

	// Set colour of bluetooth indicator, depending on phone connection status.
	function updateBluetoothIndicator() {
		var indicator = mDrawables[:Bluetooth];

		if (Sys.getDeviceSettings().phoneConnected) {
			indicator.setColor(App.getApp().getProperty("ThemeColour"));
		} else {
			indicator.setColor(App.getApp().getProperty("MeterBackgroundColour"));
		}
	}

	function updateGoalMeters() {
		updateGoalMeter(
			GOAL_TYPES[App.getApp().getProperty("LeftGoalType")],
			mDrawables[:LeftGoalMeter],
			mDrawables[:LeftGoalIcon],
			mDrawables[:LeftGoalCurrent],
			mDrawables[:LeftGoalMax]
		);

		updateGoalMeter(
			GOAL_TYPES[App.getApp().getProperty("RightGoalType")],
			mDrawables[:RightGoalMeter],
			mDrawables[:RightGoalIcon],
			mDrawables[:RightGoalCurrent],
			mDrawables[:RightGoalMax]
		);
	}

	function updateGoalMeter(goalType, meter, iconLabel, currentLabel, maxLabel) {
		var values = getValuesForGoalType(goalType);

		// Meter.
		meter.setValues(values[:current], values[:max]);

		// Icon label.
		iconLabel.setText(ICON_FONT_CHARS[goalType]);
		if (values[:isValid]) {
			iconLabel.setColor(App.getApp().getProperty("ThemeColour"));
		} else {
			iconLabel.setColor(App.getApp().getProperty("MeterBackgroundColour"));
		}		

		// Current label.
		if (values[:isValid]) {
			currentLabel.setText(values[:current].format("%d"));
		} else {
			currentLabel.setText("");
		}
		currentLabel.setColor(App.getApp().getProperty("MonoLightColour"));

		// Max/target label.
		if (values[:isValid]) {
			if (goalType == :GOAL_TYPE_BATTERY) {
				maxLabel.setText("%");
			} else {
				maxLabel.setText(values[:max].format("%d"));
			}
			
		} else {
			maxLabel.setText("");
		}
		maxLabel.setColor(App.getApp().getProperty("MonoDarkColour"));
	}

	function getValuesForGoalType(type) {
		var values = {
			:current => 0,
			:max => 1,
			:isValid => true
		};

		var info = ActivityMonitor.getInfo();

		switch(type) {
			case :GOAL_TYPE_STEPS:
				values[:current] = info.steps;
				values[:max] = info.stepGoal;
				break;

			case :GOAL_TYPE_FLOORS_CLIMBED:
				if (info has :floorsClimbed) {
					values[:current] = info.floorsClimbed;
					values[:max] = info.floorsClimbedGoal;
				} else {
					values[:isValid] = false;
				}
				
				break;

			case :GOAL_TYPE_ACTIVE_MINUTES:
				if (info has :activeMinutesWeek) {
					values[:current] = info.activeMinutesWeek.total;
					values[:max] = info.activeMinutesWeekGoal;
				} else {
					values[:isValid] = false;
				}
				break;

			case :GOAL_TYPE_BATTERY:
				// #8: floor() battery to be consistent.
				values[:current] = Math.floor(Sys.getSystemStats().battery);
				values[:max] = 100;
				break;

			case :GOAL_TYPE_CALORIES:
				values[:current] = info.calories;
				values[:max] = App.getApp().getProperty("CaloriesGoal");
				break;
		}

		// #16: If user has set goal to zero, or negative (in simulator), show as invalid. Set max to 1 to avoid divide-by-zero
		// crash in GoalMeter.getSegmentScale().
		if (values[:max] < 1) {
			values[:max] = 1;
			values[:isValid] = false;
		}

		return values;
	}

	// Set clipping region to previously-displayed seconds text only.
	// Clear background, clear clipping region, then draw new seconds.
	function onPartialUpdate(dc) {
		System.println("onPartialUpdate()");
	
		mTime.drawSeconds(dc, /* isPartialUpdate */ true);
	}

	// Called when this View is removed from the screen. Save the
	// state of this View here. This includes freeing resources from
	// memory.
	function onHide() {
	}

	// The user has just looked at their watch. Timers and animations may be started here.
	function onExitSleep() {
		mIsSleeping = false;

		Sys.println("onExitSleep()");

		// If watch does not support per-second updates, AND HideSeconds property is false,
		// show seconds, and make move bar original width.
		if (!PER_SECOND_UPDATES_SUPPORTED && !App.getApp().getProperty("HideSeconds")) {
			setHideSeconds(false);
		}
	}

	// Terminate any active timers and prepare for slow updates.
	function onEnterSleep() {
		mIsSleeping = true;

		Sys.println("onEnterSleep()");
		Sys.println("Partial updates supported = " + PER_SECOND_UPDATES_SUPPORTED);

		// If watch does not support per-second updates, then hide seconds, and make move bar full width.
		// onUpdate() is about to be called one final time before entering sleep.
		// If HideSeconds property is true, do not wastefully hide seconds again (they should already be hidden).
		if (!PER_SECOND_UPDATES_SUPPORTED && !App.getApp().getProperty("HideSeconds")) {
			setHideSeconds(true);
		}
	}

	function setHideSeconds(hideSeconds) {
		mTime.setHideSeconds(hideSeconds);
		mDrawables[:MoveBar].setFullWidth(hideSeconds);
	}

}
