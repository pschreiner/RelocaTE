#!/usr/bin/perl -w
use strict;
use Data::Dumper;
use Cwd;
use Getopt::Long;
## script take output from find_TE_insertion.pl pipeline : ***.te_insertion.all.txt
## and a bam file of the same reads used to id insertiosn
## aligned to reference genome to look for spanner
## ***.te_insertion.all.txt has the following format:
## mping   A119    Chr1    1448    C:1     R:0     L:1
##
## examples to run this script
## for i in `seq 1 12`;do mping_homozygous_heterozygous.pl Chr$i.mping.te_insertion.all.txt ../bam_files/A119_500bp_Chr$i.sorted.bam > A119.Chr$i.inserts_characterized.txt ; done
## or
## mping_homozygous_heterozygous.pl A119.mping.te_insertion.all.txt ../bam_files/ > A119.inserts_characterized.txt
## 080112 added the abiltiy to call somatic excision events with no footprint and the option to look for insertions with footprints 
## 061312 changed the values for calling homo, het, new
## 052912 added getOpts long
## 031412 added a check for XM and NM tags in sam line, if >0 then it is not 100% Match
## 022712 changed the logic for calling 'homo', 'het', 'new ins/somat' 


#my $scripts = $RealBin;
my $cwd          = getcwd();

if ( !defined @ARGV ) {
  getHelp();
}

my $sites_file ;
my $bam_dir;
my $genome_fasta;
my @bam_files;    ## can be a single .bam file or a direcotory containing .bam files
my $excision = 0;

GetOptions(
  's|sites_file:s'	=> \$sites_file,
  'b|bam_dir:s'         => \$bam_dir,
  'g|genome_fasta:s'    => \$genome_fasta,
  'x|excision:i'        => \$excision,
);

sub getHelp {
  print ' 
usage:
./characterizer.pl [-s relocaTE table output file][-b bam file or dir of bam files][-g reference genome fasta file][-h] 

options:
-s file		relocaTE output file: *.te_insertion.all.txt [no default]
-b dir/file	bam file of the orginal reads aligned to reference (before TE was trimmed) or directory of bam files [no default]
-g file		reference genome fasta file [no default]
-x int		find excision events that leave a footprint, yes or no(1|0) [0]
-h 		this help message

For more information see documentation: http://docs........

';
  exit 1;
}
if ( -d $bam_dir ) {

  #remove trailing '/'
  $bam_dir =~ s/\/$//;
  @bam_files = <$bam_dir/*bam>;
}
elsif ( -f $bam_dir or -l $bam_dir ) {
  push @bam_files, $bam_dir;
}
open INSITES, "$sites_file" or die "cannot open $sites_file $!\n";
my @dir_path = split '/', $sites_file;
my $filename = pop @dir_path;
$cwd =~ s/\/$//;    #remove trailing /
open OUTGFF, ">$cwd/$filename.homo_het.gff";
print
  "strain\tTE\tTSD\tchromosome.pos\tavg_flankers\tspanners\tstatus\n";
my %matches;
my %TSDs;
my %toPrint;
while ( my $line = <INSITES> ) {
  next if $line =~ /TE.TSD.Exper.chromosome.insertion_site/;
  next if $line =~ /total confident insertions/;
  next if $line =~ /Note:C=total read count, R=right/;
  next if $line =~ /^\s*$/;
  chomp $line;

  # mping   A119    Chr1    1448    C:1     R:0     L:1
  my ($te,$TSD,$exp,$chromosome, $pos, $total_string, $right_string, $left_string) = split /\t/, $line;
  $TSDs{$chromosome}{$pos}=$TSD;
  my ($total_count) = $total_string =~ /C:(\d+)/;
  my ($left_count)  = $left_string  =~ /L:(\d+)/;
  my ($right_count) = $right_string =~ /R:(\d+)/;

  my $Mmatch = 0;
  my $cigar_all;
  if ( $left_count >= 1  and $right_count >=  1 and $total_count >= 2) {
    my @sam_all;
    foreach my $bam_file (@bam_files) {
      ## get any alignments that overlap the insertion site
      my @sam_out = `samtools view $bam_file \'$chromosome:$pos-$pos\'`;
      push @sam_all, @sam_out;
    }

    #remove redundant lines in sam file
    my %sorted_sam;
    my $order;
    foreach my $line (@sam_all) {
      $order++;
      if ( !exists $sorted_sam{$line} ) {
        $sorted_sam{$line} = $order;
      }
    }

    #make new sorted sam array by sorting on the value of the sort hash
    my @sorted_sam =
      sort { $sorted_sam{$a} <=> $sorted_sam{$b} } keys %sorted_sam;

    foreach my $sam_line (@sorted_sam) {
      chomp $sam_line;
      my @sam_line = split /\t/, $sam_line;
      my $cigar    = $sam_line[5];
      my $flag     = $sam_line[1];
      my $seqLen   = length $sam_line[9];
      my $start    = $sam_line[3];
      my $end      = $start + $seqLen - 1;
      next unless $end >= $pos + 5;
      next unless $start <= $pos - 5;
      ## must be a all M match no soft clipping
      if ( $cigar =~ /^\d+M$/ ) {
        my ($NM) = $sam_line =~ /NM:i:(\d+)/; ## edit distance used
        my ($XM) = $sam_line =~ /XM:i:(\d+)/; ## bwa specific: mismatch count, often the same as NM, have not seen a XM>0 and NM==0
        if (defined $XM and $XM == 0){
          $Mmatch++;
        }elsif(defined $NM and $NM == 0){
          $Mmatch++;
        }elsif (!defined $NM and !defined $XM){
          $Mmatch++;
        }
      }
      elsif ( $cigar =~ /[IND]/ ) {
        $matches{"$chromosome.$pos"}{sam}{$sam_line} = 1;
      }
    }
    my $spanners         = $Mmatch;
    my $average_flankers = $total_count / 2;
    my $status           = 0;
    
    if ( $spanners == 0 ) {
      $status = 'homozygous';
    }
    elsif ( $average_flankers >= 5 and $spanners < 5 ) {
      $status = 'homozygous/excision_no_footprint';
    }
    elsif ($spanners < ($average_flankers * .2) and $spanners <= 10){
      $status = 'homozygous/excision_no_footprint';
    }
    elsif ($average_flankers <= 2 and $spanners > 10){
      $status = 'new_insertion';
    }
    elsif ( abs( $average_flankers - $spanners ) <= 5 ) {
      $status = 'heterozygous';
    }
    elsif (
      abs( $average_flankers - $spanners ) -
      ( ( $average_flankers + $spanners ) / 2 )  <= 10 ) {
      $status = 'heterozygous?';
    }
    elsif ($average_flankers > 10 and $spanners > 10){
      $status = 'heterozygous';
    }
    elsif (( ($spanners - $average_flankers) > ($spanners + $average_flankers)/2  )and( $average_flankers <= 10)){
      $status = 'new_insertion';
    }
    else{
      $status = 'other';
    }


    $matches{"$chromosome.$pos"}{status} = $status;
    $toPrint{$chromosome}{$pos}{$TSD}{TE} = $te;
    $toPrint{$chromosome}{$pos}{$TSD}{flank} = $average_flankers;
    $toPrint{$chromosome}{$pos}{$TSD}{span} = $spanners;
    $toPrint{$chromosome}{$pos}{$TSD}{status} = $status;
    $toPrint{$chromosome}{$pos}{$TSD}{strain} = $exp;
  }
}

if ($excision) {

##generate vcf of spanners looking for excision events
  my @unlink_files;
  my @vcfs;
  foreach my $pos ( keys %matches ) {
    my ( $target, $loc ) = split /\./, $pos;
    next unless exists $toPrint{$target}{$loc};
    my $range      = "$target:$pos";
    my $sam        = "$cwd/$pos.sam";
    my $bam        = "$cwd/$pos.bam";
    my $sorted_bam = "$cwd/$pos.sorted";
    my @sam_lines  = keys %{ $matches{$pos}{sam} };
    if ( @sam_lines > 1 ) {
      my $pos_sam = join "\n", @sam_lines;
      open POSSAM, ">$sam";
      print POSSAM $pos_sam;
      `samtools view -bT $genome_fasta $sam > $bam`;
      `samtools sort $bam $sorted_bam`;
      `samtools index $sorted_bam.bam`;

`samtools mpileup -C50 -ugf $genome_fasta -r $range  $sorted_bam.bam | bcftools view -bvcg - > $cwd/$pos.var.raw.bcf`;
`bcftools view $cwd/$pos.var.raw.bcf | vcfutils.pl varFilter -D 100 > $cwd/$pos.var.flt.vcf`;
      push @vcfs, "$cwd/$pos.var.flt.vcf";
      push @unlink_files, $sam, $bam, "$sorted_bam.bam.bai", "$sorted_bam.bam",
        "$cwd/$pos.var.raw.bcf", "$cwd/$pos.var.flt.vcf";
      close POSSAM;
    }
  }
##Chr1	16327633	.	GAGTACTACAATTAGTA	GAGTA	1930.0%	.	INDEL;DP=2;AF1=1;CI95=0.5,1;DP4=0,0,1,1;MQ=29;FQ=-40.5	GT:PL:GQ	1/1:58,6,0:10
  open EXCISION, ">>$cwd/excisions_with_footprint.vcfinfo" or die "can't open $cwd/excisions_with_footprint.vcfinfo for writing $!";
  foreach my $vcf (@vcfs) {
    ##Chr2.30902247.var.flt.vcf 
    my @path = split /\// , $vcf;
    my $file = pop @path;
    my ( $insert_ref, $insert_pos ) = $file =~ /(.+)\.(\d+)\.var\.flt\.vcf/;
    my $TSD = $TSDs{$insert_ref}{$insert_pos} ;
    my $TSD_len   = length $TSD;
    open VCF, $vcf;
    while ( my $line = <VCF> ) {
        next unless $line !~ /^#/;
        chomp $line;
        my ( $ref, $first_base, $col_3, $ref_seq, $strain_seq )
          = split /\t/, $line;
        my $aln_start = $first_base - $insert_pos - 1;
        my $aln_end_ref   = $first_base - length($ref_seq) - $insert_pos - 1;
        my $aln_end_strain =
          $first_base - length($strain_seq) - $insert_pos - 1;
        my $aln_end_ref_near_insert_pos    = 0;
        my $aln_end_strain_near_insert_pos = 0;
        my $aln_start_near_insert_pos      = 0;
        my $insert_bwt_ends = 0;
        my $all_values_after_insertion = 0;

        if (  ( $aln_start <= $TSD_len + 1 )
          and ( ( $aln_start * -1 <= $TSD_len + 1 ) ) )
        {
          $aln_start_near_insert_pos = 1;
        }
        if (  ( $aln_end_ref <= $TSD_len + 1 )
          and ( ( $aln_end_ref * -1 <= $TSD_len + 1 ) ) )
        {
          $aln_end_ref_near_insert_pos = 1;
        }
        if (  ( $aln_end_strain <= $TSD_len + 1 )
          and ( ( $aln_end_strain * -1 <= $TSD_len + 1 ) ) )
        {
          $aln_end_strain_near_insert_pos = 1;
        }
        my ($end_ref, $end_strain)  = (($first_base+ length($ref_seq)-1) , ($first_base+length($strain_seq)+1)); 
        if (($end_ref < $insert_pos and $end_strain > $insert_pos) 
           or ($end_strain < $insert_pos and $end_ref > $insert_pos)){
           $insert_bwt_ends = 1;
        }
        if ( (($first_base - $TSD_len + 1) > $insert_pos) and ($end_ref > $insert_pos) and ($end_strain > $insert_pos)){
           $all_values_after_insertion = 1;
        }
        ## if the alignment end in ref or in strain is close to the insertion postion,
        ## or if one is before and one is after the insertion postion,
        ## it is a potential excision with footprint
        if (
          ( $aln_end_ref_near_insert_pos or $aln_end_strain_near_insert_pos )
          or ( $insert_bwt_ends  ) 
          )
        {
          ##make sure all values are not after the insertion
          if (!$all_values_after_insertion){
            print EXCISION "$insert_ref.$insert_pos\t$line\n";
            my $status = $toPrint{$insert_ref}{$insert_pos}{$TSD}{status};
            ##only append if it already isnt there
            $toPrint{$insert_ref}{$insert_pos}{$TSD}{status} =
              $status . "/excision_with_footprint" if $status !~ /\/excision_with_footprint/; 
          }
        }
    }
  }
  unlink @unlink_files;
}

foreach my $chr( sort keys %toPrint){
  foreach my $pos (sort {$a <=> $b} keys %{$toPrint{$chr}}){
    foreach my $tsd (sort keys %{$toPrint{$chr}{$pos}}){
      my $TE = $toPrint{$chr}{$pos}{$tsd}{TE};
      my $flankers = $toPrint{$chr}{$pos}{$tsd}{flank};
      my $spanners = $toPrint{$chr}{$pos}{$tsd}{span};
      my $status = $toPrint{$chr}{$pos}{$tsd}{status};
      my $strain = $toPrint{$chr}{$pos}{$tsd}{strain};
      print "$strain\t$TE\t$tsd\t$chr.$pos\t$flankers\t$spanners\t$status\n";
      print OUTGFF
"$chr\t$strain\ttransposable_element_attribute\t$pos\t$pos\t.\t.\t.\tID=$chr.$pos.spanners;avg_flankers=$flankers;spanners=$spanners;type=$status;TE=$TE;TSD=$tsd\n";
    }
  }
}
