#! /usr/local/bin/perl
#
# Routines for converting mri files to minc format. Must be included
# with routines for reading in data structures, specific to the input
# file format.
#

sub numeric_order { $a <=> $b;}

# Subroutine to clean up files and exit
sub cleanup_and_die {

    # Get message to print and exit status
    local($message,$status) = @_;
    if (!defined($status)) {$status = 0;}
    if (defined($message)) {
        print STDERR $message;
        if ($message !~ /\n$/) {print STDERR "\n";}
    }

    $SIG{'INT'}  = 'IGNORE';
    $SIG{'TERM'} = 'IGNORE';
    $SIG{'QUIT'} = 'IGNORE';
    # Check for temp files
    if (defined($tmpdir) && -e $tmpdir) {
        print STDERR "Cleaning up temporary files.\n";
        system "rm -rf $tmpdir";
    }

    exit($status);
}

# Subroutine to execute commands and check return status
sub execute {
    local($status);
    if ($print_execution_statements) {
        print join(' ',@_),"\n";
    }
    $status = system @_;
    if ($status != 0) {
        &cleanup_and_die("Error executing command \"".join(" ",@_)."\".\n",
                         $status);
    }
}

# Subroutine to remove a list of files
sub remove_file {
    unlink @_;
}

# Subroutine to create a temporary directory (global variable $tmpdir
# is created)
sub create_tmpdir {
    local($subdir);
    if (scalar(@_) >= 1) {
        $subdir = $_[0];
    }
    else {
        $subdir = $$;
    }
    if (defined($ENV{TMPDIR})) {
        $tmpdir = $ENV{TMPDIR};
    }
    else {
        $tmpdir = "/usr/tmp";
    }
    $tmpdir .= "/$subdir";
    mkdir($tmpdir,0777) || die "Unable to create directory $tmpdir: $!";
    $SIG{'INT'}  = 'cleanup_and_die';
    $SIG{'TERM'} = 'cleanup_and_die';
    $SIG{'QUIT'} = 'cleanup_and_die';
}

# Routine to get the current tape position
sub get_tape_position {
    if (defined($counter_for_read_next_file)) {
        return $counter_for_read_next_file;
    }
    else {
        return 0;
    }
}

# Routine to set the current tape position
sub set_tape_position {
    local($tapedrive, $position) = @_;
    if (length($tapedrive) <= 0) {return;}

    # Loop to position tape
    local($repos_sleep) = 1;
    local($nreposition_retries) = 4;
    local($tmp_status);
    foreach $reposloop (0..$nreposition_retries-1) {
        select(undef, undef, undef, $repos_sleep);
        $tmp_status = system("mt -t $tapedrive rewind");
        select(undef, undef, undef, $repos_sleep);
        if ($position > 0) {
            $tmp_status = system("mt -t $tapedrive fsf $position")
                unless ($tmp_status != 0);
        }
        if ($tmp_status == 0) {last;}
        print STDERR "Error repositioning tape - trying again.\n";
    }
    if ($tmp_status != 0) {
        warn "\n\nWARNING!!!!! Unable to reposition the tape.\n\n";
    }

    # Set counter
    $counter_for_read_next_file = $position;

    return $tmp_status;
}

# Subroutine to read a file from tape
sub read_next_file {
    local($tapedrive, *input_list) = @_;
    if (!defined($tapedrive) && !defined(@input_list)) {
        $tapedrive = "/dev/nrtape";
    }

    # Constants
    $tape_block_size = 8192;
    $tape_sleep = 1;
    $retry_sleep = 1;
    $nretries = 4;


    # Get next value from list if no tape drive
    if (length($tapedrive) == 0) {
        return shift(@input_list);
    }

    # Create file counting variable if it does not exist and rewind tape
    # drive
    if (!defined($counter_for_read_next_file)) {
        print STDERR "Rewinding tape drive $tapedrive\n";
        &execute("mt -t $tapedrive rewind");
        $counter_for_read_next_file = 0;
    }

    # Create the filename
    local($cur_file_number) = $counter_for_read_next_file;
    $counter_for_read_next_file++;
    local($filename) = "$tmpdir/datafile_".$cur_file_number;

    # Try reading from the tape drive. We will try repeatedly if necessary
    print STDERR "Retrieving file $filename from drive $tapedrive\n";
    local($status);
    foreach $retryloop (0..$nretries-1) {

        # Sleep for a moment, then read from tape drive (don't ask me why,
        # it just works!)
        select(undef, undef, undef, $tape_sleep);
        $status = system("dd if=$tapedrive of=$filename ".
                         "bs=$tape_block_size >/dev/null 2>/dev/null");
        if ($status == 0) {last;}

        # If we get to here then the read failed. Try to reposition the tape.
        print STDERR "Error reading from tape - trying again.\n";
        if (&set_tape_position($tapedrive, $cur_file_number) != 0) {last;}
        $counter_for_read_next_file++;

        # Sleep to let things settle after repositioning
        select(undef, undef, undef, $retry_sleep);
        
    }

    # We've finished trying to read. Test to see if we failed or if
    # we've reached the end of the tape.
    if (($status!=0) || -z $filename) {
        if ($status != 0) {
            warn "\n\nWARNING!!!!! ".
                "Error occurred while reading tape. Giving up.\n\n\n";
            &cleanup_and_die("Not creating last minc file.\n", $status);
        }
        else {
            print STDERR "End of tape.\n";
        }
        &remove_file($filename);
        return "";
    }
    else {
        return $filename;
    }

}

# Subroutine to unpack a value from a string
sub unpack_value {
    local(*string, $offset, $type) = @_;
    return unpack("x$offset $type", $string);
}

# Subroutine to take the absolute values of an array
sub abs {
    local(@vals) = @_;
    foreach $val (@vals) {
        if ($val < 0) {$val = -$val;}
    }
    return @vals;
}

# Subroutine to get a direction cosine from a vector, correcting for
# magnitude and direction if needed (the direction cosine should point
# along the positive direction of the nearest axis)
sub get_dircos {
    if (scalar(@_) != 3) {
        die "Argument error in get_dircos\n";
    }
    local($xcos, $ycos, $zcos) = @_;

    # Get magnitude
    local($mag) = sqrt($xcos**2 + $ycos**2 + $zcos**2);
    if ($mag <= 0) {$mag = 1};

    # Make sure that direction cosine is pointing along positive axis
    local($max) = $xcos;
    if (&abs($ycos) > &abs($max)) {$max= $ycos;}
    if (&abs($zcos) > &abs($max)) {$max= $zcos;}
    if ($max < 0) {$mag *= -1;}

    # Correct components
    $xcos /= $mag;
    $ycos /= $mag;
    $zcos /= $mag;

    return ($xcos, $ycos, $zcos);
}

# Subroutine to add an optional attribute to an array
sub add_optional_attribute {
    if (scalar(@_) != 3) {
        die "Argument error in add_optional_attribute\n";
    }
    local(*array, $name, $value) = @_;

    if (length($value) > 0) {
        push(@array, "-attribute", $name."=".$value);
    }
}

# Subroutine to create a minc file
sub create_mincfile {
    if (scalar(@_) != 5) {
        die "Argument error in create_mincfile";
    }
    local($mincfile, *file_list, *mincinfo, $image_list, $echo) 
        = @_;

    # Sort images by z position
    local($cur_image, %pos_to_image, @positions, $cur_slicepos);
    foreach $cur_image (split($;, $image_list)) {
        $cur_slicepos = $mincinfo{$cur_image, 'slicepos'};
        if (!defined($pos_to_image{$cur_slicepos})) {
            $pos_to_image{$cur_slicepos} = $cur_image;
            push(@positions, $cur_slicepos);
        }
    }
    @positions = sort(numeric_order @positions);

    # Get smallest step size and get nslices and ordered list of images
    local(@image_list, $slicestep, $nslices, $slicestart, $slicerange);
    if (scalar(@positions) > 1) {
        $slicestep = $positions[1] - $positions[0];
        foreach $i (2..$#positions) {
            local($diff) = $positions[$i] - $positions[$i-1];
            if (($diff < $slicestep) && ($diff > 0)) {
                $diff = $slicestep;
            }
        }
        if ($slicestep <= 0) {
            $nslices = scalar(@positions);
            $slicestep = 1;
            @image_list = @pos_to_image{@positions};
        }
        else {
            local($first_image, $last_image);
            $first_image = $pos_to_image{$positions[0]};
            $last_image = $pos_to_image{$positions[$#positions]};
            $slicerange = $mincinfo{$last_image, 'slicepos'} -
                $mincinfo{$first_image, 'slicepos'};
            $nslices = int($slicerange / $slicestep + 1.5);
            # Improve accuracy of $slicestep
            $slicestep = $slicerange / ($nslices - 1);
            foreach $i (0..$nslices) {
                $image_list[$i] = '';
            }
            foreach $position (@positions) {
                local($slice) = 
                    int(($position - $positions[0]) / $slicestep + 0.5);
                @image_list[$slice] = $pos_to_image{$position};
            }
        }
    }
    else {
        $slicestep = 1;
        $nslices = 1;
        @image_list = @pos_to_image{@positions};
    }
    $slicestart = $positions[0];

    # Check for existence of file - create a new name if it exists
    local($filebase);
    if ($mincfile =~ /^(.*)\.mnc$/) {
        $filebase = $1;
    }
    else {
        $filebase = $mincfile;
    }
    local($version) = 1;
    while (-e $mincfile) {
        $version++;
        $mincfile = $filebase."_version$version.mnc";
        print STDERR "Minc file already exists. Trying name \"$mincfile\".\n";
    }

    # Set up rawtominc command

    # Dimension info
    local($nrows, $ncols, $orientation, $pixel_size);
    local($xstep, $ystep, $zstep);
    local($colstart, $rowstart);
    $pixel_size = $mincinfo{'pixel_size'};
    $nrows = $mincinfo{'height'};
    $ncols = $mincinfo{'width'};
    $xstep = $mincinfo{'colstep'};
    $ystep = $mincinfo{'rowstep'};
    $zstep = $slicestep;
    $colstart = $mincinfo{'colstart'}+0;
    $rowstart = $mincinfo{'rowstart'}+0;

    # Orientation
    local($xstart, $ystart, $zstart);
    local(%world_axes);
    local($orient_flag) = $mincinfo{'orientation'};
    if ($orient_flag eq 'sagittal') {    # Sagittal
        ($ystep, $zstep, $xstep) = 
            ($mincinfo{'colstep'}, $mincinfo{'rowstep'}, $slicestep);
        ($ystart, $zstart, $xstart) = ($colstart, $rowstart, $slicestart);
        $orientation = "-sagittal";
        %world_axes = ('col', 'y', 'row', 'z', 'slc', 'x');
    }
    elsif ($orient_flag eq 'coronal') { # Coronal
        ($xstep, $zstep, $ystep) = 
            ($mincinfo{'colstep'}, $mincinfo{'rowstep'}, $slicestep);
        ($xstart, $zstart, $ystart) = ($colstart, $rowstart, $slicestart);
        $orientation = "-coronal";
        %world_axes = ('col', 'x', 'row', 'z', 'slc', 'y');
    }
    else {                      # Transverse
        ($xstep, $ystep, $zstep) = 
            ($mincinfo{'colstep'}, $mincinfo{'rowstep'}, $slicestep);
        ($xstart, $ystart, $zstart) = ($colstart, $rowstart, $slicestart);
        $orientation = "-transverse";
        %world_axes = ('col', 'x', 'row', 'y', 'slc', 'z');
    }
    local(@dircos_options) = ();
    foreach $axis ('col', 'row', 'slc') {
        if (defined($mincinfo{"${axis}_dircos_x"})) {
            push(@dircos_options,"-${world_axes{$axis}}dircos");
            foreach $component ('x', 'y', 'z') {
                push(@dircos_options, $mincinfo{"${axis}_dircos_$component"});
            }
        }
    }

    # Optional attributes
    local(@optional_attributes) = ();
    &add_optional_attribute(*optional_attributes, 
                            "acquisition:repetition_time", $mincinfo{'tr'});
    &add_optional_attribute(*optional_attributes, 
                            "acquisition:echo_time", $mincinfo{'te',$echo});
    &add_optional_attribute(*optional_attributes,
                            "acquisition:inversion_time", $mincinfo{'ti'});
    &add_optional_attribute(*optional_attributes, 
                            "acquisition:flip_angle", $mincinfo{'mr_flip'});
    &add_optional_attribute(*optional_attributes, 
                            "acquisition:scanning_sequence", 
                            $mincinfo{'scan_seq'});
    &add_optional_attribute(*optional_attributes, 
                            "study:study_id", $mincinfo{'exam'});
    &add_optional_attribute(*optional_attributes, 
                            "study:acquisition_id", $mincinfo{'series'});
    &add_optional_attribute(*optional_attributes, 
                            "study:start_time", $mincinfo{'start_time'});
    &add_optional_attribute(*optional_attributes, 
                            "study:institution", $mincinfo{'institution'});
    &add_optional_attribute(*optional_attributes, 
                            "patient:birthdate", 
                            $mincinfo{'patient_birthdate'});
    &add_optional_attribute(*optional_attributes, 
                            "patient:age", $mincinfo{'patient_age'});
    &add_optional_attribute(*optional_attributes, 
                            "patient:sex", $mincinfo{'patient_sex'});
    &add_optional_attribute(*optional_attributes, 
                            "patient:identification", $mincinfo{'patient_id'});

    # GE specific stuff
    local(@ge_specific_attributes);
    @ge_specific_attributes = ();
    &add_optional_attribute(*ge_specific_attributes,
                            "ge_mrimage:pseq", $mincinfo{'ge_pseq'});
    &add_optional_attribute(*ge_specific_attributes,
                            "ge_mrimage:pseqmode", $mincinfo{'ge_pseqmode'});

    # Run rawtominc with appropriate arguments
    $| = 1;
    open(MINC, "|-") || exec
        ("rawtominc", $mincfile, $nslices, $nrows, $ncols, "-noclobber",
         "-scan_range", "-short", "-range", "0", "4095", $orientation,
         "-xstep", $xstep, "-ystep", $ystep, "-zstep", $zstep,
         "-xstart", $xstart, "-ystart", $ystart, "-zstart", $zstart,
         @dircos_options,
         "-mri", 
         "-attribute", "patient:full_name=".$mincinfo{'patient_name'},
         @optional_attributes,
         @ge_specific_attributes,
         );

    # Get keys for machine specific file info
    local(@specific_keys, %specific_keys, $key);
    undef(%specific_keys);
    foreach $key (keys(%mincinfo)) {
        $key =~ /$;specific$;([^$;]*)$/;
        $specific_keys{$1} = '';
    }
    @specific_keys = keys(%specific_keys);

    # Loop through slices
    local($cur_file, %specific_file_info, $cur_image);
    foreach $slice (0..$nslices-1) {

        # Get image number
        $cur_image = $image_list[$slice];

        # Get file name
        $cur_file = $file_list{$cur_image};

        # Print log message
        if (length($cur_file) > 0) {
            print STDERR 
                "Getting data from file \"$cur_file\" for slice $slice.\n";
        }
        else {
            print STDERR "Using blank image for slice $slice.\n";
        }

        # Set up variables for getting the image
        $image_data_len = $nrows * $ncols * $pixel_size;

        # Read the image (if not defined, create a blank image)
        if (length($cur_file) <= 0) {
            $image_data = pack("x$image_data_len",());
        }
        else {
            # Get machine specific file info 
            undef(%specific_file_info);
            foreach $key (@specific_keys) {
                $specific_file_info{$key} = 
                    $mincinfo{$cur_image, 'specific', $key};
            }

            local($image_cmd) = 
                &get_image_cmd($cur_file, *specific_file_info);
            open(GEDAT, $image_cmd . " |");
            read(GEDAT, $image_data, $image_data_len);
            close(GEDAT);
            if ($? != 0) {
                &cleanup_and_die("Error or signal while reading image.\n", $?);
            }
            if (length($image_data) != $image_data_len) {
                close(MINC);
                warn "Error reading image from $cur_file ".
                    "while creating minc file \"$mincfile\"";
                return;
            }
        }

        # Write out the image
        print MINC $image_data;
    }

    # Close the minc file
    close(MINC);
    if ($? != 0) {
        &cleanup_and_die("Error or signal while writing image.\n", $?);
    }

}

# Routine to add to the list file
sub save_list_info {
    local($listfile, $mincfile, *mincinfo, $image_list, $echo) = @_;
    local($pos) = $mincinfo{'tape_position'};
    local($pat_name) = '"'.substr($mincinfo{'patient_name'},0,30).'"';
    local($exam) = $mincinfo{'exam'};
    local($acq) = $mincinfo{'series'};
    local($nslc) = scalar(split($;, $image_list));
    local($date) = '"'.substr($mincinfo{'start_time'},0,30).'"';
    local($inst) = '"'.substr($mincinfo{'institution'},0,30).'"';
    open(LIST, ">>$listfile") || 
        warn "Error writing to list file \"$listfile\" ($!)\n";
    write LIST;
    close(LIST);
    format LIST =
@>>>> @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @>>>>>>> @>> @> @>> @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$pos  $pat_name                        $exam    $acq $echo $nslc $date $inst
.
}

# Routine to get argument values
sub get_arguments {

    # Usage line
    $0 =~ /([^\/]+)$/;
    local($prog) = $1;
    local($usage) = 
        "Usage: $prog <outputdir> [<file1> <file2> ...] [<options>]\n";

    # Set default values
    local($outputdir) = undef;
    local($tapedrive) = '';
    local($listfile) = '';
    local($nominc) = 0;
    local($tape_position) = 0;
    local($tape_end) = -1;
    local(@input_list) = ();

    # Loop through arguments
    while (@_) {
        $_ = shift;
        if (/^-list$/) { $listfile = shift;}
        elsif (/^-tape$/) { $tapedrive = shift;}
        elsif (/^-nominc$/) { $nominc = 1;}
        elsif (/^-first$/) { $tape_position = shift;}
        elsif (/^-last$/) {$tape_end = shift;}
        elsif (/^-h(|elp)$/) {
            die
"Command-specific options:
 -list:\t\tSpecify a file for listing contents of tape
 -tape:\t\tSpecify an input tape drive (default=/dev/nrtape if no files given)
 -nominc:\t\tDo not produce output minc files
 -first:\t\tSpecify a starting tape position (# files to skip)
 -last:\t\tSpecify an ending tape position
Generic options for all commands:
 -help:\t\tPrint summary of comand-line options and abort

$usage
";
        }
        elsif (/^-./) {
            die "Unknown option \"$_\"\n";
        }
        else {
            if (!defined($outputdir)) {
                $outputdir = $_;
            }
            else {
                push(@input_list, $_);
            }
        }
    }

    # Check expected values
    if ((length($tapedrive) > 0) && (scalar(@input_list) > 0)) {
        die "You cannot specify both a tape drive and a file list.\n";
    }
    elsif ((length($tapedrive) <= 0) && (scalar(@input_list) <= 0)) {
        $tapedrive = "/dev/nrtape";
    }
    if (!defined($outputdir)) {
        die $usage;
    }
    if ($tape_position < 0) {
        die "Tape position must be >= 0\n";
    }
    if (!defined($tape_end)) {$tape_end = -1;}

    # Return values
    return($outputdir, $tapedrive, $listfile, $nominc, 
           $tape_position, $tape_end, @input_list);
}

# Subroutine to do all the work - loops through files collecting info,
# then calls routine to create minc file.
# Because this was the main program, it uses global variables
sub mri_to_minc {

    $| = 1;

    # Get arguments
    ($outputdir, $tapedrive, $listfile, $nominc, 
     $tape_position, $tape_end, @input_list) = 
         &get_arguments(@_);

    # Should we delete the files?
    $delete_files = (length($tapedrive) > 0);

    # Create a temporary directory
    &create_tmpdir("mri_to_minc_$$");

    # Check if list file already exists
    if (length($listfile) > 0) {
        if (-e $listfile) {
            die "List file \"$listfile\" already exists.\n";
        }
        open(LIST_START, ">$listfile") || 
            die "Unable to write to list file \"$listfile\" ($!)\n";
        write LIST_START;
        close(LIST_START);
        format LIST_START =
@>>>> @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @>>>>>>> @>> @> @>> @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
'File'  'Patient Name' 'Exam' 'Acq' 'E#' 'Slc' 'Date' 'Institution'

.
    }

    # Rewind and initialize the tape
    if (length($tapedrive) > 0) {
        &initialize_tape_drive($tapedrive);
        if ($tape_position > 0) {
            &set_tape_position($tapedrive, $tape_position);
        }
    }

    # Loop through files on tape
    $keep_looping = 1;
    while ($keep_looping) {

        # Save current tape position
        $tape_position = &get_tape_position;

        # Check for reaching last tape file requested
        if (($tape_end >= 0) && ($tape_position > $tape_end)) {
            warn "Reached last file requested (file number $tape_end).\n";
            $keep_looping = 0;
        }

        # Get next file
        if ($keep_looping) {
            $nextfile = &read_next_file($tapedrive, *input_list);
            if ($nextfile eq "") {
                $keep_looping = 0;
            }
        }

        # Read in headers
        if ($keep_looping) {
            undef(%file_info, %specific_file_info);
            if (&read_file_info($nextfile, *file_info, *specific_file_info)) {
                warn "Error reading file \"$nextfile\". Skipping to next.";
                next;
            }

            # Get interesting values
            $cur_numechos = $file_info{'numechos'};
            $cur_exam = $file_info{'exam'};
            $cur_series = $file_info{'series'};
            $cur_echo = $file_info{'echo'};
            $cur_image = $file_info{'image'} * $cur_numechos + $cur_echo;
            $cur_width = $file_info{'width'};
            $cur_height = $file_info{'height'};
            $cur_slicepos = $file_info{'slicepos'};
        }

        # Check if number exam or series has changed or if this is the 
        # last file
        if ((scalar(keys(%file_list)) > 0) &&
            (!$keep_looping || 
             ($mincinfo{'exam'} ne $cur_exam) || 
             ($mincinfo{'series'} != $cur_series))) {

            # Loop through echos
            @echos = sort(numeric_order keys(%echo_list));
            if (scalar(@echos) > $mincinfo{'numechos'}) {
                $mincinfo{'numechos'} = scalar(@echos);
            }
            foreach $echo (@echos) {

                # Create minc file
                ($patient_name = $mincinfo{'patient_name'}) =~
                    tr/a-zA-Z0-9_\-/_/cs;             # Use only legal chars
                $patient_name =~ tr/A-Z/a-z/;         # Lowercase
                $patient_name =~ s/_*(.*[^_])_*$/$1/; # Remove _ on ends
                $mincfile = "$outputdir/".$patient_name."_".
                    $mincinfo{'exam'}."_".$mincinfo{'series'};
                if ($mincinfo{'numechos'} > 1) {
                    $mincfile .= "_e$echo";
                }
                $mincfile .= "_mri.mnc";
                if (length($listfile) > 0) {
                    &save_list_info($listfile, $mincfile, *mincinfo, 
                                    $image_list{$echo}, $echo);
                }
                if (!$nominc) {
                    print STDERR "Creating minc file \"$mincfile\"\n";
                    &create_mincfile($mincfile, *file_list, *mincinfo, 
                                     $image_list{$echo}, $echo);
                }
                else {
                    print STDERR "Not creating minc file \"$mincfile\"\n";
                }
            }

            # Delete files (if needed) and reset variables
            if ($delete_files) {
                &remove_file(values(%file_list));
            }
            undef(%file_list, %echo_list, %image_list, %mincinfo);
        }

        # Break out here if stopping loop
        if (!$keep_looping) {next;}

        # If first file, then save appropriate info
        if (scalar(keys(%file_list)) <= 0) {
            $mincinfo{'tape_position'} = $tape_position;
            $mincinfo{'exam'} = $cur_exam;
            $mincinfo{'series'} = $cur_series;
            $mincinfo{'width'} = $cur_width;
            $mincinfo{'height'} = $cur_height;
            $mincinfo{'pixel_size'} = $file_info{'pixel_size'};
            $mincinfo{'patient_name'} = $file_info{'patient_name'};
            $mincinfo{'orientation'} = $file_info{'orientation'};
            $mincinfo{'tr'} = $file_info{'tr'};
            $mincinfo{'ti'} = $file_info{'ti'};
            $mincinfo{'mr_flip'} = $file_info{'mr_flip'};
            $mincinfo{'scan_seq'} = $file_info{'scan_seq'};
            $mincinfo{'ge_pseq'} = $file_info{'ge_pseq'};
            $mincinfo{'ge_pseqmode'} = $file_info{'ge_pseqmode'};
            $mincinfo{'start_time'} = $file_info{'start_time'};
            $mincinfo{'institution'} = $file_info{'institution'};
            $mincinfo{'patient_birthdate'} = $file_info{'patient_birthdate'};
            $mincinfo{'patient_age'} = $file_info{'patient_age'};
            $mincinfo{'patient_sex'} = $file_info{'patient_sex'};
            $mincinfo{'patient_id'} = $file_info{'patient_id'};
            $mincinfo{'colstep'} = $file_info{'colstep'};
            $mincinfo{'rowstep'} = $file_info{'rowstep'};
            $mincinfo{'colstart'} = $file_info{'colstart'};
            $mincinfo{'rowstart'} = $file_info{'rowstart'};
            $mincinfo{'col_dircos_x'} = $file_info{'col_dircos_x'};
            $mincinfo{'col_dircos_y'} = $file_info{'col_dircos_y'};
            $mincinfo{'col_dircos_z'} = $file_info{'col_dircos_z'};
            $mincinfo{'row_dircos_x'} = $file_info{'row_dircos_x'};
            $mincinfo{'row_dircos_y'} = $file_info{'row_dircos_y'};
            $mincinfo{'row_dircos_z'} = $file_info{'row_dircos_z'};
            $mincinfo{'slc_dircos_x'} = $file_info{'slc_dircos_x'};
            $mincinfo{'slc_dircos_y'} = $file_info{'slc_dircos_y'};
            $mincinfo{'slc_dircos_z'} = $file_info{'slc_dircos_z'};
        }
        else {
            if (($cur_width != $mincinfo{'width'}) || # 
                ($cur_height != $mincinfo{'height'})) {
                warn "Width or height do not match first file ".
                    "for file $nextfile. Skipping to next.";
                next;
            }
        }

        # Save echo number
        if (!defined($mincinfo{'te', $cur_echo})) {
            $mincinfo{'te', $cur_echo} = $file_info{'te'};
        }

        # Save info for all files
        foreach $key (keys(%specific_file_info)) {
            $mincinfo{$cur_image, 'specific', $key} =
                $specific_file_info{$key};
        }
        $mincinfo{$cur_image, 'slicepos'} = $cur_slicepos;

        # Keep track of files, image numbers and echo numbers
        $file_list{$cur_image} = $nextfile;
        $echo_list{$cur_echo} = '';
        if (defined($image_list{$cur_echo})) {$image_list{$cur_echo} .= $; ;}
        $image_list{$cur_echo} .= $cur_image;

    }

    # Rewind the tape
    if (length($tapedrive) > 0) {
        &execute("mt -t $tapedrive rewind");
    }

    &cleanup_and_die();
}

